param(
    [switch] $Prepare,
    [string] $OutputPath = "",
    [switch] $SmokeTest,
    [switch] $CheckSource
)

$ErrorActionPreference = "Stop"

# PowerShell compiles an immutable helper. JavaScript runtimes execute it
# directly; OTP opens native cmd.exe in the helper cache directory because its
# Windows port driver rejects managed ConsoleApplication images. User arguments
# and environment overrides stay in process-scoped, base64-encoded metadata and
# never enter that fixed command. The helper starts the command suspended,
# assigns it to a kill-on-close Job Object, and only then lets user code run.
$source = @'
using System;
using System.Collections;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class KangarooWindowsJob
{
    private const string Prefix = "__KANGAROO_INTERNAL_WINDOWS_JOB_V1_";
    private const uint CREATE_SUSPENDED = 0x00000004;
    private const uint STARTF_USESTDHANDLES = 0x00000100;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const uint DUPLICATE_SAME_ACCESS = 0x00000002;
    private const int JobObjectBasicAccountingInformation = 1;
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint INFINITE = 0xFFFFFFFF;
    private const uint WAIT_OBJECT_0 = 0;
    private const int STD_INPUT_HANDLE = -10;
    private const int STD_OUTPUT_HANDLE = -11;
    private const int STD_ERROR_HANDLE = -12;

    public static int Main()
    {
        try
        {
            string executable = DecodeValue("EXECUTABLE");
            string directory = DecodeValue("DIRECTORY");
            string argv0 = DecodeValue("ARGV0");
            string countText = DecodeValue("ARGUMENT_COUNT");
            int count;
            if (!Int32.TryParse(
                    countText,
                    NumberStyles.None,
                    CultureInfo.InvariantCulture,
                    out count) || count < 0 || count > 65535)
                throw new InvalidOperationException(
                    "invalid internal argument count");

            string[] arguments = new string[count];
            for (int index = 0; index < count; index++)
            {
                arguments[index] = DecodeValue(
                    "ARGUMENT_" + index.ToString("D6"));
            }
            string environmentCountText = DecodeValue("ENVIRONMENT_COUNT");
            int environmentCount;
            if (!Int32.TryParse(
                    environmentCountText,
                    NumberStyles.None,
                    CultureInfo.InvariantCulture,
                    out environmentCount) ||
                environmentCount < 0 || environmentCount > 65535)
                throw new InvalidOperationException(
                    "invalid internal environment count");
            string[] environmentNames = new string[environmentCount];
            string[] environmentValues = new string[environmentCount];
            for (int index = 0; index < environmentCount; index++)
            {
                string suffix = index.ToString("D6");
                environmentNames[index] = DecodeValue(
                    "ENVIRONMENT_NAME_" + suffix);
                environmentValues[index] = DecodeValue(
                    "ENVIRONMENT_VALUE_" + suffix);
            }
            RemoveInternalVariables();
            for (int index = 0; index < environmentCount; index++)
            {
                Environment.SetEnvironmentVariable(
                    environmentNames[index],
                    environmentValues[index],
                    EnvironmentVariableTarget.Process);
            }
            return Run(executable, directory, argv0, arguments);
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(
                "kangaroo: Windows process wrapper failed: " +
                CompleteMessage(error));
            return 2;
        }
    }

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

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DuplicateHandle(
        IntPtr sourceProcess,
        IntPtr sourceHandle,
        IntPtr targetProcess,
        out IntPtr targetHandle,
        uint desiredAccess,
        bool inheritHandle,
        uint options);

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
        IntPtr standardInput = IntPtr.Zero;
        IntPtr standardOutput = IntPtr.Zero;
        IntPtr standardError = IntPtr.Zero;
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
            standardInput = DuplicateStandardHandle(STD_INPUT_HANDLE);
            standardOutput = DuplicateStandardHandle(STD_OUTPUT_HANDLE);
            standardError = DuplicateStandardHandle(STD_ERROR_HANDLE);
            startup.hStdInput = standardInput;
            startup.hStdOutput = standardOutput;
            startup.hStdError = standardError;

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

            CloseHandle(standardInput);
            standardInput = IntPtr.Zero;
            CloseHandle(standardOutput);
            standardOutput = IntPtr.Zero;
            CloseHandle(standardError);
            standardError = IntPtr.Zero;

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

            TerminateRemainingProcesses(job);
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
            if (standardInput != IntPtr.Zero) CloseHandle(standardInput);
            if (standardOutput != IntPtr.Zero) CloseHandle(standardOutput);
            if (standardError != IntPtr.Zero) CloseHandle(standardError);
            if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
            if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
            if (job != IntPtr.Zero) CloseHandle(job);
        }
    }

    private static IntPtr DuplicateStandardHandle(int standardHandle)
    {
        IntPtr source = GetStdHandle(standardHandle);
        CheckHandle(source, "GetStdHandle");
        IntPtr duplicate;
        IntPtr currentProcess = GetCurrentProcess();
        Check(
            DuplicateHandle(
                currentProcess,
                source,
                currentProcess,
                out duplicate,
                0,
                true,
                DUPLICATE_SAME_ACCESS),
            "DuplicateHandle");
        return duplicate;
    }

    private static void TerminateRemainingProcesses(IntPtr job)
    {
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting =
            QueryAccounting(job);
        if (accounting.ActiveProcesses == 0) return;

        Check(TerminateJobObject(job, 2), "TerminateJobObject");
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

    private static string DecodeValue(string name)
    {
        string encoded = Environment.GetEnvironmentVariable(Prefix + name);
        if (encoded == null)
            throw new InvalidOperationException(
                "missing internal process value: " + name);
        return Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
    }

    private static void RemoveInternalVariables()
    {
        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
        {
            string name = Convert.ToString(
                entry.Key,
                CultureInfo.InvariantCulture);
            if (name.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase))
                Environment.SetEnvironmentVariable(name, null);
        }
    }

    private static string CompleteMessage(Exception error)
    {
        StringBuilder message = new StringBuilder();
        Exception current = error;
        while (current != null)
        {
            if (message.Length != 0) message.Append(": ");
            message.Append(current.Message);
            current = current.InnerException;
        }
        return message.ToString();
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
        int code = Marshal.GetLastWin32Error();
        return new Win32Exception(
            code,
            operation + " failed with Windows error " +
            code.ToString(CultureInfo.InvariantCulture));
    }
}
'@

$prefix = "__KANGAROO_INTERNAL_WINDOWS_JOB_V1_"
$executableName = "windows-job-v6-20260831.exe"

function Decode-Value([string] $name) {
    $encoded = [Environment]::GetEnvironmentVariable(
        $prefix + $name,
        [EnvironmentVariableTarget]::Process)
    if ($null -eq $encoded) {
        throw "missing internal process value: $name"
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
}

function Encode-Value([string] $value) {
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value))
}

function Get-Helper-Path {
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        return [IO.Path]::GetFullPath($OutputPath)
    }
    $encodedOutputPath = [Environment]::GetEnvironmentVariable(
        $prefix + "OUTPUT_PATH",
        [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($encodedOutputPath)) {
        $decodedOutputPath = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($encodedOutputPath))
        return [IO.Path]::GetFullPath($decodedOutputPath)
    }
    return [IO.Path]::Combine(
        [IO.Path]::GetTempPath(),
        "kangaroo",
        $executableName)
}

function Ensure-Job-Executable {
    $executable = Get-Helper-Path
    if (-not [IO.Path]::IsPathRooted($executable)) {
        throw "Windows process helper path must be absolute"
    }
    $cacheDirectory = [IO.Path]::GetDirectoryName($executable)
    [IO.Directory]::CreateDirectory($cacheDirectory) | Out-Null

    if ([IO.File]::Exists($executable)) {
        return $executable
    }

    $candidate = [IO.Path]::Combine(
        $cacheDirectory,
        ([Guid]::NewGuid().ToString("N") + ".exe"))
    try {
        Add-Type -TypeDefinition $source -Language CSharp `
            -OutputAssembly $candidate -OutputType ConsoleApplication
        try {
            [IO.File]::Move($candidate, $executable)
        }
        catch {
            if (-not [IO.File]::Exists($executable)) {
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
    return $executable
}

function Set-Smoke-Launch(
    [string] $executable,
    [string[]] $arguments
) {
    $values = @{
        "EXECUTABLE" = $executable
        "DIRECTORY" = (Get-Location).ProviderPath
        "ARGV0" = $executable
        "ARGUMENT_COUNT" = $arguments.Length.ToString(
            [Globalization.CultureInfo]::InvariantCulture)
        "ENVIRONMENT_COUNT" = "0"
    }
    for ($index = 0; $index -lt $arguments.Length; $index++) {
        $values["ARGUMENT_{0:D6}" -f $index] = $arguments[$index]
    }
    foreach ($entry in $values.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable(
            $prefix + $entry.Key,
            (Encode-Value $entry.Value),
            [EnvironmentVariableTarget]::Process)
    }
}

try {
    if ($CheckSource) {
        Add-Type -TypeDefinition $source -Language CSharp
        [Environment]::Exit(0)
    }

    $helper = Ensure-Job-Executable
    if ($Prepare) {
        [Environment]::Exit(0)
    }

    if (-not $SmokeTest) {
        throw "specify -Prepare or -SmokeTest"
    }

    $find = (Get-Command "findstr.exe" -ErrorAction Stop).Source
    Set-Smoke-Launch $find @("kangaroo")
    $output = "kangaroo" | & $helper
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Windows process helper smoke test exited $exitCode"
    }
    if (($output -join "`n").Trim() -ne "kangaroo") {
        throw "Windows process helper did not preserve redirected stdio"
    }

    Set-Smoke-Launch $find @("not-present")
    $null = "kangaroo" | & $helper
    if ($LASTEXITCODE -ne 1) {
        throw "Windows process helper did not preserve the child exit code"
    }
    [Environment]::Exit(0)
}
catch {
    [Console]::Error.WriteLine(
        "kangaroo: Windows process helper preparation failed: " +
        $_.Exception.Message)
    [Environment]::Exit(2)
}
