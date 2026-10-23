// Let the networking plugin inspect its own on-disk signature for cloud camera requests.
// The stock plugin ignores externally supplied Executable-info, and the cloud rejects
// metadata from our non-Bambu host. Verified with macOS plugin 02.08.02.60 and an H2C.
// Only calls originating in that exact plugin image are redirected. Security.framework
// still reads the real signature and returns its actual result; no validity result is changed.
#include <Security/Security.h>
#include <dlfcn.h>
#include <limits.h>
#include <atomic>
#include <cstdlib>
#include <cstring>

namespace {
char plugin_path[PATH_MAX]{};
std::atomic<unsigned> inspections{0};

OSStatus plugin_signing_source(CFURLRef path, SecCSFlags flags, SecStaticCodeRef* code)
{
    Dl_info caller{};
    char caller_path[PATH_MAX]{};
    if (plugin_path[0] && dladdr(__builtin_return_address(0), &caller) && caller.dli_fname &&
        realpath(caller.dli_fname, caller_path) && std::strcmp(caller_path, plugin_path) == 0) {
        CFURLRef source = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
            reinterpret_cast<const UInt8*>(plugin_path), std::strlen(plugin_path), false);
        if (!source) return errSecAllocate;
        const OSStatus result = SecStaticCodeCreateWithPath(source, flags, code);
        CFRelease(source);
        ++inspections;
        return result;
    }
    return SecStaticCodeCreateWithPath(path, flags, code);
}

__attribute__((used, section("__DATA,__interpose")))
const struct { const void* replacement; const void* original; } interpose = {
    reinterpret_cast<const void*>(plugin_signing_source),
    reinterpret_cast<const void*>(SecStaticCodeCreateWithPath)
};
}

// Configure once, before dlopen starts the plugin or any of its workers.
extern "C" bool camera_signature_use_plugin(const char* path)
{
    return realpath(path, plugin_path) != nullptr;
}
extern "C" unsigned camera_signature_inspections() { return inspections.load(); }
