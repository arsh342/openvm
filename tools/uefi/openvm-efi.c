/* openvm-efi.c — the Windows boot chain for Apple's firmware, without patches.
 *
 * Loads the framebuffer driver (\EFI\BOOT\OPENVM-FB.EFI, a boot-service driver
 * that gives the firmware's Graphics Output instances a linear framebuffer),
 * then starts Windows Boot Manager from the same volume, unmodified.
 *
 * With PMU emulation on (GuestWindows.setBool), Boot Manager and winload run as
 * Microsoft shipped them.
 *
 * Freestanding: no C library, no EDK2 library.
 * Written against the UEFI specification.
 */

#include <Uefi.h>
#include <stdarg.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#include <Protocol/SimpleTextOut.h>

/* --- GUIDs ----------------------------------------------------------- */

static EFI_GUID gSimpleFileSystemGuid = {
    0x964e5b22, 0x6459, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
static EFI_GUID gLoadedImageGuid = {
    0x5b1b31a1, 0x9562, 0x11d2, {0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
static EFI_GUID gOpenVMVendorGuid = {
    0x6f70656e, 0x766d, 0x2d01, {0x49, 0x02, 0x9a, 0x3c, 0x1d, 0x77, 0x55, 0x0e}};
static EFI_GUID gDevicePathGuid = {
    0x09576e91, 0x6d3f, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};

static EFI_GUID gGlobalVariableGuid = {
    0x8be4df61, 0x93ca, 0x11d2, {0xaa, 0x0d, 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c}};

#define MEDIA_DEVICE_PATH_TYPE 0x04
#define MEDIA_FILEPATH_SUBTYPE 0x04

#define PROBE_TEXT "openvm-efi-ok"

#ifndef BS_ALL_HANDLES
#define BS_ALL_HANDLES 0
#endif
#ifndef BS_BY_PROTOCOL
#define BS_BY_PROTOCOL 2
#endif

/* --- Freestanding helpers ------------------------------------------- */

void *memcpy(void *dst, const void *src, UINTN n) {
    UINT8 *d = dst;
    const UINT8 *s = src;
    while (n--)
        *d++ = *s++;
    return dst;
}
void *memset(void *dst, int c, UINTN n) {
    UINT8 *d = dst;
    while (n--)
        *d++ = (UINT8)c;
    return dst;
}

/* --- Probe helpers --------------------------------------------------- */

static void publish_text(EFI_RUNTIME_SERVICES *rt, CHAR16 *name, const char *text) {
    CHAR8 payload[256];
    UINTN n = 0;
    while (*text && n < sizeof(payload) - 1)
        payload[n++] = *text++;
    payload[n] = '\0';
    rt->SetVariable(name, &gOpenVMVendorGuid,
                    EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS |
                        EFI_VARIABLE_RUNTIME_ACCESS,
                    n, payload);
}

static void write_probe_files(EFI_BOOT_SERVICES *bs) {
    EFI_HANDLE *handles = NULL;
    UINTN count = 0;
    if (bs->LocateHandleBuffer(BS_BY_PROTOCOL, &gSimpleFileSystemGuid, NULL, &count, &handles) ==
        EFI_SUCCESS) {
        for (UINTN i = 0; i < count; i++) {
            EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs = NULL;
            EFI_FILE_PROTOCOL *root = NULL, *file = NULL;
            if (bs->HandleProtocol(handles[i], &gSimpleFileSystemGuid, (void **)&fs) ==
                    EFI_SUCCESS &&
                fs && fs->OpenVolume(fs, &root) == EFI_SUCCESS && root &&
                root->Open(root, &file, L"openvm-probe.txt",
                           EFI_FILE_MODE_CREATE | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_READ,
                           0) == EFI_SUCCESS &&
                file) {
                UINTN size = sizeof(PROBE_TEXT);
                file->Write(file, &size, PROBE_TEXT);
                file->Close(file);
            }
            if (root)
                root->Close(root);
        }
        if (handles)
            bs->FreePool(handles);
    }
}

/* --- Loading a sibling image from our own volume ---------------------
 *
 * img->FilePath is only this app's file node, with no device part, so LoadImage
 * cannot resolve a path built from it. A loadable path is the volume's own device
 * path, from its handle, plus one file node, and the parent is this image. */
/* The full device path of a file on our own volume: the volume's device path
 * plus one file node. Caller frees with FreePool; *size includes the end node. */
static UINT8 *sibling_path(EFI_BOOT_SERVICES *bs, EFI_LOADED_IMAGE_PROTOCOL *img,
                           const CHAR16 *path, UINTN *size) {
    EFI_DEVICE_PATH_PROTOCOL *dev = NULL;
    if (bs->HandleProtocol(img->DeviceHandle, &gDevicePathGuid, (void **)&dev) != EFI_SUCCESS ||
        dev == NULL)
        return NULL;
    UINTN devLen = 0;
    UINT8 *node = (UINT8 *)dev;
    for (UINTN hops = 0; hops < 64; hops++) { /* bytes before the end node */
        UINTN len = node[2] | (node[3] << 8);
        if (node[0] == 0x7f || len < 4)
            break;
        devLen += len;
        node += len;
    }
    UINTN nameLen = 0;
    while (path[nameLen])
        nameLen++;
    UINTN fileNodeSize = 4 + (nameLen + 1) * sizeof(CHAR16);
    UINT8 *buf = NULL;
    if (bs->AllocatePool(EfiBootServicesData, devLen + fileNodeSize + 4, (void **)&buf) !=
        EFI_SUCCESS)
        return NULL;
    memcpy(buf, dev, devLen);
    UINT8 *fn = buf + devLen;
    fn[0] = MEDIA_DEVICE_PATH_TYPE;
    fn[1] = MEDIA_FILEPATH_SUBTYPE;
    fn[2] = fileNodeSize & 0xff;
    fn[3] = (fileNodeSize >> 8) & 0xff;
    for (UINTN i = 0; i <= nameLen; i++) {
        fn[4 + i * 2] = path[i] & 0xff;
        fn[5 + i * 2] = (path[i] >> 8) & 0xff;
    }
    UINT8 *end = fn + fileNodeSize;
    end[0] = 0x7f;
    end[1] = 0xff;
    end[2] = 4;
    end[3] = 0;
    *size = devLen + fileNodeSize + 4;
    return buf;
}

static EFI_STATUS load_sibling(EFI_BOOT_SERVICES *bs, EFI_HANDLE self,
                               EFI_LOADED_IMAGE_PROTOCOL *img, const CHAR16 *path,
                               EFI_HANDLE *child) {
    UINTN size = 0;
    UINT8 *buf = sibling_path(bs, img, path, &size);
    if (buf == NULL)
        return EFI_NOT_FOUND;
    EFI_STATUS st = bs->LoadImage(FALSE, self, (EFI_DEVICE_PATH_PROTOCOL *)buf, NULL, 0, child);
    bs->FreePool(buf);
    return st;
}

/* --- Framebuffer driver loading -------------------------------------- */

#define FB_DRIVER_PATH L"\\EFI\\BOOT\\OPENVM-FB.EFI"

static EFI_STATUS load_framebuffer_driver(EFI_BOOT_SERVICES *bs, EFI_HANDLE self,
                                          EFI_LOADED_IMAGE_PROTOCOL *img) {
    EFI_HANDLE child = NULL;
    EFI_STATUS st = load_sibling(bs, self, img, FB_DRIVER_PATH, &child);
    if (st != EFI_SUCCESS)
        return st;
    st = bs->StartImage(child, NULL, NULL);
    /* The firmware may already have loaded it from Driver0000 (below). */
    return st == EFI_ALREADY_STARTED ? EFI_SUCCESS : st;
}

/* Register the framebuffer driver with the firmware as Driver0000.
 *
 * Windows adds its own "Windows Boot Manager" boot option on first boot and
 * puts it first in BootOrder, pointing straight at bootmgfw.efi. Every restart
 * after that skips this chainloader, so the framebuffer driver never loads and
 * the VM dies the moment Boot Manager draws (measured: first boot errored at
 * ~90 s, the restart; the next boot errored at 1.1 s). Driver#### entries are
 * the UEFI mechanism for exactly this: the firmware loads them before any boot
 * option, whichever one is chosen. Replacing bootmgfw.efi instead would be
 * undone by the next Windows update. */
static void register_fb_driver(EFI_RUNTIME_SERVICES *rt, EFI_BOOT_SERVICES *bs,
                               EFI_LOADED_IMAGE_PROTOCOL *img) {
    UINTN pathSize = 0;
    UINT8 *path = sibling_path(bs, img, FB_DRIVER_PATH, &pathSize);
    if (path == NULL)
        return;
    static const CHAR16 desc[] = L"openVM framebuffer";
    UINTN optSize = 4 + 2 + sizeof(desc) + pathSize;
    UINT8 *opt = NULL;
    if (bs->AllocatePool(EfiBootServicesData, optSize, (void **)&opt) != EFI_SUCCESS) {
        bs->FreePool(path);
        return;
    }
    opt[0] = 1;
    opt[1] = 0;
    opt[2] = 0;
    opt[3] = 0; /* LOAD_OPTION_ACTIVE */
    opt[4] = pathSize & 0xff;
    opt[5] = (pathSize >> 8) & 0xff;
    memcpy(opt + 6, desc, sizeof(desc));
    memcpy(opt + 6 + sizeof(desc), path, pathSize);
    bs->FreePool(path);

    const UINT32 attrs =
        EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS;
    /* Skip the flash write when an identical entry is already there. */
    UINT8 existing[512];
    UINTN existingSize = sizeof existing;
    UINT32 existingAttrs = 0;
    int same = rt->GetVariable(L"Driver0000", &gGlobalVariableGuid, &existingAttrs, &existingSize,
                               existing) == EFI_SUCCESS &&
               existingSize == optSize;
    for (UINTN i = 0; same && i < optSize; i++)
        same = existing[i] == opt[i];
    if (!same)
        rt->SetVariable(L"Driver0000", &gGlobalVariableGuid, attrs, optSize, opt);
    bs->FreePool(opt);

    /* DriverOrder must list 0x0000; keep any other drivers after it. */
    UINT16 order[32];
    UINTN orderSize = sizeof order;
    UINT32 orderAttrs = 0;
    if (rt->GetVariable(L"DriverOrder", &gGlobalVariableGuid, &orderAttrs, &orderSize, order) !=
        EFI_SUCCESS)
        orderSize = 0;
    for (UINTN i = 0; i < orderSize / 2; i++)
        if (order[i] == 0x0000)
            return;
    UINT16 next[33];
    next[0] = 0x0000;
    for (UINTN i = 0; i < orderSize / 2 && i < 32; i++)
        next[i + 1] = order[i];
    rt->SetVariable(L"DriverOrder", &gGlobalVariableGuid, attrs, orderSize + 2, next);
}

/* --- Boot Manager chainload ------------------------------------------ */

static EFI_STATUS chainload_bootmgfw(EFI_BOOT_SERVICES *bs, EFI_HANDLE self,
                                     EFI_LOADED_IMAGE_PROTOCOL *img) {
    EFI_HANDLE child = NULL;
    EFI_STATUS st = load_sibling(bs, self, img, L"\\EFI\\Microsoft\\Boot\\bootmgfw.efi", &child);
    if (st != EFI_SUCCESS)
        return st;
    return bs->StartImage(child, NULL, NULL);
}

/* --- EfiMain --------------------------------------------------------- */

EFI_STATUS EFIAPI EfiMain(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable) {
    EFI_RUNTIME_SERVICES *rt = SystemTable->RuntimeServices;
    EFI_BOOT_SERVICES *bs = SystemTable->BootServices;

    /* 1. Publish probe markers */
    write_probe_files(bs);
    publish_text(rt, L"OpenVMEfiLoaded", "1");

    /* 2. Get LoadedImage protocol for our path */
    EFI_LOADED_IMAGE_PROTOCOL *img = NULL;
    bs->HandleProtocol(ImageHandle, &gLoadedImageGuid, (void **)&img);

    /* 3. Load framebuffer driver first, and register it with the firmware so
     *    boots that bypass this chainloader still get it. */
    EFI_STATUS st = load_framebuffer_driver(bs, ImageHandle, img);
    register_fb_driver(rt, bs, img);
    if (st != EFI_SUCCESS) {
        publish_text(rt, L"OpenVMFbLoadFailed", "1");
    } else {
        publish_text(rt, L"OpenVMEfiLoaded", "fb-ok");
    }

    /* 4. Chainload Windows Boot Manager */
    st = chainload_bootmgfw(bs, ImageHandle, img);
    if (st != EFI_SUCCESS) {
        publish_text(rt, L"OpenVMChainloadFailed", "1");
    }

    /* We never return if chainload succeeds */
    return st;
}