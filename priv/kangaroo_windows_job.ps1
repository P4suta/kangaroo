param([switch] $Prepare)

$ErrorActionPreference = "Stop"

# The command and its arguments arrive through process-scoped environment
# variables so PowerShell never reparses user arguments. The native launcher
# starts the command suspended, assigns it to a kill-on-close Job Object, and
# only then lets user code run. This closes the race where a fast command could
# fork and exit before Kangaroo acquired ownership of its descendants.
$source = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class KangarooWindowsJob
{
    private const uint CREATE_SUSPENDED = 0x00000004;
    private const uint STARTF_USESTDHANDLES = 0x00000100;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const int JobObjectBasicAccountingInformation = 1;
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint INFINITE = 0xFFFFFFFF;
    private const uint WAIT_OBJECT_0 = 0;
    private const int STD_INPUT_HANDLE = -10;
    private const int STD_OUTPUT_HANDLE = -11;
    private const int STD_ERROR_HANDLE = -12;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
    {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job,
        int informationClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION information,
        uint informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(
        IntPtr job,
        int informationClass,
        ref JOBOBJECT_BASIC_ACCOUNTING_INFORMATION information,
        uint informationLength,
        IntPtr returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int standardHandle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint SearchPath(
        string path,
        string fileName,
        string extension,
        int bufferLength,
        StringBuilder buffer,
        out IntPtr filePart);

    public static int Run(
        string executable,
        string directory,
        string argv0,
        string[] arguments)
    {
        IntPtr job = IntPtr.Zero;
        PROCESS_INFORMATION process = new PROCESS_INFORMATION();
        bool created = false;
        try
        {
            job = CreateJobObject(IntPtr.Zero, null);
            CheckHandle(job, "CreateJobObject");

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits =
                new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags =
                JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            Check(
                SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    ref limits,
                    (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))),
                "SetInformationJobObject");

            STARTUPINFO startup = new STARTUPINFO();
            startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            startup.dwFlags = STARTF_USESTDHANDLES;
            startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
            startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
            startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);

            string resolvedExecutable = ResolveExecutable(executable);
            StringBuilder commandLine = BuildCommandLine(argv0, arguments);
            Check(
                CreateProcess(
                    resolvedExecutable,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    CREATE_SUSPENDED,
                    IntPtr.Zero,
                    directory,
                    ref startup,
                    out process),
                "CreateProcess");
            created = true;

            Check(AssignProcessToJobObject(job, process.hProcess),
                "AssignProcessToJobObject");
            if (ResumeThread(process.hThread) == UInt32.MaxValue)
                throw LastError("ResumeThread");
            CloseHandle(process.hThread);
            process.hThread = IntPtr.Zero;

            if (WaitForSingleObject(process.hProcess, INFINITE) != WAIT_OBJECT_0)
                throw LastError("WaitForSingleObject");

            uint exitCode;
            Check(GetExitCodeProcess(process.hProcess, out exitCode),
                "GetExitCodeProcess");

            DrainRemainingProcesses(job);
            return unchecked((int)exitCode);
        }
        catch
        {
            if (created && process.hProcess != IntPtr.Zero)
                TerminateProcess(process.hProcess, 2);
            if (job != IntPtr.Zero)
                TerminateJobObject(job, 2);
            throw;
        }
        finally
        {
            if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
            if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
            if (job != IntPtr.Zero) CloseHandle(job);
        }
    }

    private static void DrainRemainingProcesses(IntPtr job)
    {
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting =
            QueryAccounting(job);
        if (accounting.ActiveProcesses == 0) return;

        Check(TerminateJobObject(job, 2), "TerminateJobObject");
        DateTime deadline = DateTime.UtcNow.AddSeconds(5);
        while (QueryAccounting(job).ActiveProcesses != 0)
        {
            if (DateTime.UtcNow >= deadline)
                throw new TimeoutException(
                    "Windows Job Object did not drain within 5000 ms");
            Thread.Sleep(1);
        }
    }

    private static JOBOBJECT_BASIC_ACCOUNTING_INFORMATION QueryAccounting(
        IntPtr job)
    {
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting =
            new JOBOBJECT_BASIC_ACCOUNTING_INFORMATION();
        Check(
            QueryInformationJobObject(
                job,
                JobObjectBasicAccountingInformation,
                ref accounting,
                (uint)Marshal.SizeOf(
                    typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)),
                IntPtr.Zero),
            "QueryInformationJobObject");
        return accounting;
    }

    private static StringBuilder BuildCommandLine(
        string argv0,
        string[] arguments)
    {
        StringBuilder commandLine = new StringBuilder();
        commandLine.Append(QuoteArgument(argv0));
        foreach (string argument in arguments)
        {
            commandLine.Append(' ');
            commandLine.Append(QuoteArgument(argument));
        }
        return commandLine;
    }

    private static string ResolveExecutable(string executable)
    {
        StringBuilder buffer = new StringBuilder(32768);
        IntPtr filePart;
        uint length = SearchPath(
            null,
            executable,
            null,
            buffer.Capacity,
            buffer,
            out filePart);
        if (length == 0 && Path.GetExtension(executable).Length == 0)
        {
            length = SearchPath(
                null,
                executable,
                ".exe",
                buffer.Capacity,
                buffer,
                out filePart);
        }
        if (length == 0) throw LastError("SearchPath");
        if (length >= buffer.Capacity)
            throw new InvalidOperationException(
                "resolved executable path exceeds 32767 characters");
        return buffer.ToString();
    }

    // CreateProcess uses the CommandLineToArgvW backslash-and-quote contract.
    private static string QuoteArgument(string argument)
    {
        if (argument.IndexOf('\0') >= 0)
            throw new ArgumentException("process arguments cannot contain NUL");
        if (argument.Length > 0 &&
            argument.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            return argument;

        StringBuilder quoted = new StringBuilder();
        quoted.Append('"');
        int backslashes = 0;
        foreach (char character in argument)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                quoted.Append('\\', backslashes * 2 + 1);
                quoted.Append('"');
                backslashes = 0;
                continue;
            }
            quoted.Append('\\', backslashes);
            backslashes = 0;
            quoted.Append(character);
        }
        quoted.Append('\\', backslashes * 2);
        quoted.Append('"');
        return quoted.ToString();
    }

    private static void Check(bool succeeded, string operation)
    {
        if (!succeeded) throw LastError(operation);
    }

    private static void CheckHandle(IntPtr handle, string operation)
    {
        if (handle == IntPtr.Zero || handle == new IntPtr(-1))
            throw LastError(operation);
    }

    private static Exception LastError(string operation)
    {
        return new Win32Exception(
            Marshal.GetLastWin32Error(),
            operation + " failed");
    }
}
'@

$prefix = "__KANGAROO_INTERNAL_WINDOWS_JOB_V1_"
$assemblyName = "windows-job-v1-20260830.dll"

function Ensure-Job-Type {
    $cacheDirectory = [IO.Path]::Combine(
        [IO.Path]::GetTempPath(),
        "kangaroo")
    [IO.Directory]::CreateDirectory($cacheDirectory) | Out-Null
    $assembly = [IO.Path]::Combine($cacheDirectory, $assemblyName)

    if ([IO.File]::Exists($assembly)) {
        try {
            Add-Type -Path $assembly
            return
        }
        catch {
            [IO.File]::Delete($assembly)
        }
    }

    $candidate = [IO.Path]::Combine(
        $cacheDirectory,
        ([Guid]::NewGuid().ToString("N") + ".dll"))
    try {
        Add-Type -TypeDefinition $source -Language CSharp `
            -OutputAssembly $candidate
        try {
            [IO.File]::Move($candidate, $assembly)
        }
        catch {
            if (-not [IO.File]::Exists($assembly)) {
                throw
            }
            [IO.File]::Delete($candidate)
        }
    }
    finally {
        if ([IO.File]::Exists($candidate)) {
            [IO.File]::Delete($candidate)
        }
    }
}

function Decode-Value([string] $name) {
    $encoded = [Environment]::GetEnvironmentVariable(
        $prefix + $name,
        [EnvironmentVariableTarget]::Process)
    if ($null -eq $encoded) {
        throw "missing internal process value: $name"
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
}

try {
    Ensure-Job-Type
    if ($Prepare) {
        [Environment]::Exit(0)
    }

    $executable = Decode-Value "EXECUTABLE"
    $directory = Decode-Value "DIRECTORY"
    $argv0 = Decode-Value "ARGV0"
    $countText = Decode-Value "ARGUMENT_COUNT"
    $count = [Int32]::Parse(
        $countText,
        [Globalization.CultureInfo]::InvariantCulture)
    if ($count -lt 0 -or $count -gt 65535) {
        throw "invalid internal argument count"
    }

    $arguments = New-Object 'string[]' $count
    for ($index = 0; $index -lt $count; $index++) {
        $name = "ARGUMENT_{0:D6}" -f $index
        $arguments[$index] = Decode-Value $name
    }

    foreach ($key in [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process).Keys) {
        $name = [string] $key
        if ($name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $null,
                [EnvironmentVariableTarget]::Process)
        }
    }

    $exitCode = [KangarooWindowsJob]::Run(
        $executable,
        $directory,
        $argv0,
        $arguments)
    [Environment]::Exit($exitCode)
}
catch {
    [Console]::Error.WriteLine(
        "kangaroo: Windows process wrapper failed: " + $_.Exception.Message)
    [Environment]::Exit(2)
}
