// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

#if UNIX
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Microsoft.PowerShell
{
    internal static class UnixCoreDumpPolicy
    {
        // RLIMIT_CORE is 4 on Linux and macOS. A zero hard limit prevents an
        // unprivileged child from re-enabling dumps; both limits survive exec.
        private const int CoreResource = 4;

        internal static bool TryApply(out string error)
        {
            ResourceLimit limit = default;
            if (setrlimit(CoreResource, in limit) == 0)
            {
                error = null;
                return true;
            }

            error = new Win32Exception(Marshal.GetLastPInvokeError()).Message;
            return false;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ResourceLimit
        {
            // rlim_t is unsigned 64-bit on the supported Linux x64/arm64 and
            // macOS platforms. Both fields are deliberately initialized to zero.
            internal ulong Current;
            internal ulong Maximum;
        }

        [DllImport("libc", SetLastError = true)]
        private static extern int setrlimit(int resource, in ResourceLimit limit);
    }
}
#endif
