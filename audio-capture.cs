using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

/// <summary>
/// Windows waveIn recorder: 16000 Hz, signed 16-bit little-endian PCM, mono.
/// Drain returns raw PCM (no WAV header). Call Stop and Dispose deterministically.
/// Start begins a new recording and clears previously queued audio and errors.
/// </summary>
public sealed class VTPcmRecorder : IDisposable
{
    private const int SampleRate = 16000;
    private const int BytesPerSecond = SampleRate * 2;
    private const int BufferBytes = BytesPerSecond / 10; // 100 ms
    private const int BufferCount = 6;
    private const int MaximumBufferedBytes = BytesPerSecond * 30;
    private const int StopTimeoutMilliseconds = 5000;
    private const uint CallbackFunction = 0x00030000;
    private const uint WaveMapper = 0xffffffff;
    private const uint WimData = 0x03c0;

    // Lifecycle calls serialize separately: waveInReset may wait for callbacks,
    // so it MUST NOT execute while holding the callback's state lock.
    private readonly object lifecycleLock = new object();
    private readonly object stateLock = new object();
    private readonly Queue<byte[]> blocks = new Queue<byte[]>();
    private readonly SortedDictionary<long, byte[]> completed = new SortedDictionary<long, byte[]>();
    private readonly Dictionary<IntPtr, NativeBuffer> buffers = new Dictionary<IntPtr, NativeBuffer>();
    private readonly WaveInCallback callback;
    private IntPtr device;
    private GCHandle selfRoot;
    private bool hasSelfRoot;
    private bool disposed;
    private bool allowRequeue;
    private volatile bool isRunning;
    private int activeCallbacks;
    private int bufferedBytes;
    private long nextSubmission;
    private long nextCompletion;
    private Exception captureError;

    public VTPcmRecorder()
    {
        callback = OnWaveIn;
    }

    /// <summary>False after Stop, or once a capture/queue error is detected.</summary>
    public bool IsRunning { get { return isRunning; } }

    /// <summary>
    /// Opens the default Windows input device and starts continuous capture.
    /// Calling Start while running is a no-op. A prior incomplete native cleanup
    /// must be retried with Stop/Dispose before starting a new recording.
    /// </summary>
    public void Start()
    {
        lock (lifecycleLock)
        {
            lock (stateLock)
            {
                ThrowIfDisposed();
                if (isRunning) return;
                if (device != IntPtr.Zero)
                    throw new InvalidOperationException("Previous capture still owns native resources. Call Stop or Dispose before restarting.");
                blocks.Clear();
                completed.Clear();
                bufferedBytes = 0;
                nextSubmission = 0;
                nextCompletion = 0;
                captureError = null;
                allowRequeue = false;
            }
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                throw new PlatformNotSupportedException("VTPcmRecorder requires Windows winmm waveIn.");

            try
            {
                // A delegate field alone cannot keep an abandoned recorder alive.
                // This root survives until waveInClose succeeds, including failed
                // cleanup attempts. Explicit disposal is therefore mandatory.
                selfRoot = GCHandle.Alloc(this);
                hasSelfRoot = true;
                WaveFormat format = new WaveFormat();
                format.wFormatTag = 1; // WAVE_FORMAT_PCM
                format.nChannels = 1;
                format.nSamplesPerSec = SampleRate;
                format.nAvgBytesPerSec = BytesPerSecond;
                format.nBlockAlign = 2;
                format.wBitsPerSample = 16;
                format.cbSize = 0;
                IntPtr openedDevice;
                uint result = waveInOpen(out openedDevice, WaveMapper, ref format,
                    callback, GCHandle.ToIntPtr(selfRoot), CallbackFunction);
                Check(result, "waveInOpen");
                device = openedDevice;

                for (int i = 0; i < BufferCount; i++)
                {
                    NativeBuffer buffer = AllocateBuffer();
                    lock (stateLock) { buffers.Add(buffer.Header, buffer); }
                    Check(waveInPrepareHeader(device, buffer.Header, HeaderSize), "waveInPrepareHeader");
                    buffer.Prepared = true;
                    lock (stateLock)
                    {
                        buffer.Sequence = nextSubmission++;
                        buffer.Queued = true;
                        result = waveInAddBuffer(device, buffer.Header, HeaderSize);
                        if (result != 0) buffer.Queued = false;
                    }
                    Check(result, "waveInAddBuffer");
                }
                lock (stateLock)
                {
                    allowRequeue = true;
                    isRunning = true;
                }
                Check(waveInStart(device), "waveInStart");
            }
            catch (Exception startError)
            {
                List<Exception> errors = new List<Exception>();
                errors.Add(startError);
                CleanupNative(errors);
                ThrowErrors(errors);
            }
        }
    }

    /// <summary>
    /// Stops capture, resets outstanding buffers, and waits for returned headers
    /// and callbacks before releasing memory. Queued PCM remains available to
    /// Drain. Capture faults (including overflow) and cleanup faults are thrown.
    /// If safe cleanup cannot be established, native memory stays allocated and
    /// this recorder stays rooted; Stop/Dispose can be retried safely.
    /// </summary>
    public void Stop()
    {
        lock (lifecycleLock)
        {
            List<Exception> errors = new List<Exception>();
            CleanupNative(errors);
            lock (stateLock)
            {
                if (captureError != null) errors.Insert(0, captureError);
            }
            ThrowErrors(errors);
        }
    }

    /// <summary>
    /// Atomically returns and removes all queued PCM in submission order.
    /// Returns an empty array if no blocks are ready. Capture errors are sticky
    /// until the next Start and are thrown rather than returning truncated audio.
    /// </summary>
    public byte[] Drain()
    {
        lock (stateLock)
        {
            ThrowIfDisposed();
            if (captureError != null) throw captureError;
            int size = 0;
            foreach (byte[] block in blocks) size += block.Length;
            if (size == 0) return new byte[0];
            byte[] audio = new byte[size];
            int offset = 0;
            while (blocks.Count != 0)
            {
                byte[] block = blocks.Dequeue();
                Buffer.BlockCopy(block, 0, audio, offset, block.Length);
                offset += block.Length;
            }
            bufferedBytes -= size; // includes not-yet-contiguous completions
            return audio;
        }
    }

    /// <summary>
    /// Stops capture and releases native resources; throws cleanup errors if
    /// release cannot be proven safe. Call Stop/Drain to observe capture errors.
    /// Repeated Dispose retries an incomplete cleanup, otherwise it is a no-op.
    /// </summary>
    public void Dispose()
    {
        lock (lifecycleLock)
        {
            lock (stateLock)
            {
                if (disposed && device == IntPtr.Zero) return;
                disposed = true;
            }
            List<Exception> errors = new List<Exception>();
            CleanupNative(errors);
            if (device == IntPtr.Zero)
            {
                lock (stateLock)
                {
                    blocks.Clear();
                    completed.Clear();
                    bufferedBytes = 0;
                }
            }
            ThrowErrors(errors);
        }
    }

    private void OnWaveIn(IntPtr handle, uint message, IntPtr instance, IntPtr headerPointer, IntPtr unused)
    {
        if (message != WimData) return;
        Interlocked.Increment(ref activeCallbacks);
        try
        {
            lock (stateLock)
            {
                NativeBuffer buffer;
                if (!buffers.TryGetValue(headerPointer, out buffer) || !buffer.Queued)
                {
                    FailCapture(new InvalidOperationException("waveIn returned an unknown or duplicate audio buffer."));
                    return;
                }
                buffer.Queued = false;
                WaveHeader header = (WaveHeader)Marshal.PtrToStructure(headerPointer, typeof(WaveHeader));
                if (header.dwBytesRecorded > BufferBytes || (header.dwBytesRecorded & 1) != 0)
                {
                    FailCapture(new InvalidOperationException("waveIn returned an invalid PCM byte count."));
                    return;
                }
                if (captureError == null)
                {
                    int length = (int)header.dwBytesRecorded;
                    if (bufferedBytes + length > MaximumBufferedBytes)
                    {
                        FailCapture(new InvalidOperationException("PCM capture queue overflow: more than 30 seconds of undrained audio. Recording is incomplete; call Stop before restarting."));
                        return;
                    }
                    byte[] data = new byte[length];
                    if (length != 0) Marshal.Copy(buffer.Data, data, 0, length);
                    // Function callbacks may race: header submission sequence,
                    // not callback lock acquisition order, defines audio order.
                    completed.Add(buffer.Sequence, data);
                    bufferedBytes += length;
                    byte[] ready;
                    while (completed.TryGetValue(nextCompletion, out ready))
                    {
                        completed.Remove(nextCompletion++);
                        if (ready.Length != 0) blocks.Enqueue(ready);
                    }
                }
                if (allowRequeue)
                {
                    buffer.Sequence = nextSubmission++;
                    buffer.Queued = true;
                    // Serialized with Stop disabling allowRequeue. Reset itself
                    // runs outside this lock, after all requeue calls have left.
                    uint result = waveInAddBuffer(handle, buffer.Header, HeaderSize);
                    if (result != 0)
                    {
                        buffer.Queued = false;
                        // Avoid error-text P/Invoke from a driver callback.
                        FailCapture(new InvalidOperationException("waveInAddBuffer (callback) failed (MMRESULT " + result + ")."));
                    }
                }
            }
        }
        catch (Exception error)
        {
            // Never unwind a managed exception through winmm's callback frame.
            lock (stateLock) { FailCapture(error); }
        }
        finally
        {
            lock (stateLock)
            {
                Interlocked.Decrement(ref activeCallbacks);
                Monitor.PulseAll(stateLock);
            }
        }
    }

    // Requires stateLock. No native calls or PowerShell/UI callbacks here.
    private void FailCapture(Exception error)
    {
        if (captureError == null) captureError = error;
        allowRequeue = false;
        isRunning = false;
    }

    // Requires lifecycleLock, but never stateLock across reset/unprepare/close.
    private void CleanupNative(List<Exception> errors)
    {
        lock (stateLock)
        {
            allowRequeue = false;
            isRunning = false;
        }
        if (device != IntPtr.Zero)
        {
            try { AddNativeError(errors, waveInReset(device), "waveInReset"); }
            catch (Exception error) { errors.Add(error); }

            Stopwatch wait = Stopwatch.StartNew();
            lock (stateLock)
            {
                while (!AllBuffersReturned() || Volatile.Read(ref activeCallbacks) != 0)
                {
                    int remaining = StopTimeoutMilliseconds - (int)wait.ElapsedMilliseconds;
                    if (remaining <= 0)
                    {
                        errors.Add(new TimeoutException("waveIn callbacks/buffers did not drain within 5 seconds. Native memory is retained for safety; retry Stop or Dispose."));
                        return;
                    }
                    Monitor.Wait(stateLock, remaining);
                }
            }
            bool allUnprepared = true;
            foreach (NativeBuffer buffer in buffers.Values)
            {
                if (!buffer.Prepared) continue;
                try
                {
                    uint result = waveInUnprepareHeader(device, buffer.Header, HeaderSize);
                    if (result == 0) buffer.Prepared = false;
                    else
                    {
                        allUnprepared = false;
                        AddNativeError(errors, result, "waveInUnprepareHeader");
                    }
                }
                catch (Exception error)
                {
                    allUnprepared = false;
                    errors.Add(error);
                }
            }
            if (!allUnprepared) return;
            try
            {
                uint result = waveInClose(device);
                if (result != 0)
                {
                    AddNativeError(errors, result, "waveInClose");
                    return;
                }
                device = IntPtr.Zero;
            }
            catch (Exception error)
            {
                errors.Add(error);
                return;
            }
        }
        // Successful close is the final native ownership barrier. Never free
        // on STILLPLAYING, reset timeout, or close failure.
        lock (stateLock)
        {
            foreach (NativeBuffer buffer in buffers.Values)
            {
                Marshal.FreeHGlobal(buffer.Header);
                Marshal.FreeHGlobal(buffer.Data);
            }
            buffers.Clear();
        }
        if (hasSelfRoot)
        {
            selfRoot.Free();
            hasSelfRoot = false;
        }
        GC.KeepAlive(callback);
    }

    private bool AllBuffersReturned()
    {
        foreach (NativeBuffer buffer in buffers.Values)
            if (buffer.Queued) return false;
        return true;
    }

    private static NativeBuffer AllocateBuffer()
    {
        IntPtr data = Marshal.AllocHGlobal(BufferBytes);
        IntPtr header = IntPtr.Zero;
        try
        {
            header = Marshal.AllocHGlobal((int)HeaderSize);
            WaveHeader value = new WaveHeader();
            value.lpData = data;
            value.dwBufferLength = BufferBytes;
            Marshal.StructureToPtr(value, header, false);
            return new NativeBuffer { Header = header, Data = data };
        }
        catch
        {
            if (header != IntPtr.Zero) Marshal.FreeHGlobal(header);
            Marshal.FreeHGlobal(data);
            throw;
        }
    }

    private void ThrowIfDisposed()
    {
        if (disposed) throw new ObjectDisposedException("VTPcmRecorder");
    }

    private static void Check(uint result, string operation)
    {
        if (result != 0) throw NativeError(result, operation);
    }

    private static void AddNativeError(List<Exception> errors, uint result, string operation)
    {
        if (result != 0) errors.Add(NativeError(result, operation));
    }

    private static Exception NativeError(uint result, string operation)
    {
        StringBuilder text = new StringBuilder(256);
        uint translated = waveInGetErrorText(result, text, (uint)text.Capacity);
        return new InvalidOperationException(operation + " failed (MMRESULT " + result + ")" +
            (translated == 0 ? ": " + text.ToString() : "."));
    }

    private static void ThrowErrors(List<Exception> errors)
    {
        if (errors.Count == 1) throw errors[0];
        if (errors.Count > 1) throw new AggregateException("PCM capture or cleanup failed.", errors);
    }

    private sealed class NativeBuffer
    {
        public IntPtr Header;
        public IntPtr Data;
        public bool Prepared;
        public bool Queued;
        public long Sequence;
    }

    // WAVEFORMATEX is 18 bytes. WAVEHDR uses native pointer alignment:
    // sizeof(WAVEHDR) = 48 on Windows x64 and 32 on Windows x86.
    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct WaveFormat
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WaveHeader
    {
        public IntPtr lpData;
        public uint dwBufferLength;
        public uint dwBytesRecorded;
        public UIntPtr dwUser;
        public uint dwFlags;
        public uint dwLoops;
        public IntPtr lpNext;
        public UIntPtr reserved;
    }

    private static readonly uint HeaderSize = (uint)Marshal.SizeOf(typeof(WaveHeader));

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void WaveInCallback(IntPtr handle, uint message, IntPtr instance, IntPtr param1, IntPtr param2);

    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInOpen(out IntPtr handle, uint deviceId, ref WaveFormat format,
        WaveInCallback callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInPrepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInUnprepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInAddBuffer(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInStart(IntPtr handle);
    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInReset(IntPtr handle);
    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInClose(IntPtr handle);
    [DllImport("winmm.dll", EntryPoint = "waveInGetErrorTextW", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern uint waveInGetErrorText(uint error, StringBuilder text, uint characters);
}
