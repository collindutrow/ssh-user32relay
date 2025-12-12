const std = @import("std");
const win32 = @import("win32");

const foundation = win32.foundation;
const threading = win32.system.threading;
const security = win32.security;

/// Indicates whether this process is running with elevated privileges.
pub var is_elevated: bool = false;

/// Check if the current process is running with elevated privileges.
pub fn isProcessElevated() !bool {
    // Pseudo-handle, always valid
    const proc = threading.GetCurrentProcess();

    // Need QUERY access
    const desired_access = security.TOKEN_ACCESS_MASK{
        .QUERY = 1,
    };

    // Open process token
    var token: ?foundation.HANDLE = null;
    const ok = threading.OpenProcessToken(
        proc,
        desired_access,
        &token,
    );
    if (ok == 0 or token == null) {
        return error.OpenProcessTokenFailed;
    }
    const nonnull_token = token.?;
    defer _ = foundation.CloseHandle(nonnull_token);

    // Query TOKEN_ELEVATION
    var elevation: security.TOKEN_ELEVATION = undefined;
    var returned: u32 = 0;

    const ok2 = security.GetTokenInformation(
        nonnull_token,
        security.TOKEN_INFORMATION_CLASS.TokenElevation,
        &elevation,
        @sizeOf(security.TOKEN_ELEVATION),
        &returned,
    );
    if (ok2 == 0) {
        return error.GetTokenInformationFailed;
    }

    return elevation.TokenIsElevated != 0;
}
