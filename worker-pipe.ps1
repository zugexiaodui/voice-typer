# worker 子进程 stdio 桥：stdout 由独立后台线程持续排空；stdin 由有界队列 + 后台线程写入。
# 不在 PowerShell 回调/线程里执行 scriptblock，UI 线程只做无阻塞取行和有界写等待。
# 这样即使 worker 一次输出 >4 KB（Windows 匿名管道容量）的行，也不会把它卡在同步写里。

if (-not ('VTWorkerPipe' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;

public sealed class VTWorkerPipe : IDisposable {
  sealed class LineItem {
    public string Text;
    public int Bytes;
  }
  sealed class WriteRequest {
    public byte[] Data;
    public ManualResetEventSlim Done = new ManualResetEventSlim(false);
    public Exception Error;
  }

  readonly object gate = new object();
  readonly Queue<LineItem> lines = new Queue<LineItem>();
  readonly Queue<WriteRequest> writes = new Queue<WriteRequest>();
  readonly TextReader stdout;
  readonly Stream stdin;
  readonly Thread readerThread;
  readonly Thread writerThread;
  readonly int maxQueueBytes;
  readonly int maxQueueLines;
  readonly int maxWriteBytes;
  readonly int maxWriteCount;
  readonly int overflowWaitMs;

  int queuedLineBytes;
  long queuedWriteBytes;
  bool eof;
  bool faulted;
  bool disposed;
  string lastError = "";

  public VTWorkerPipe(TextReader stdout, Stream stdin,
      int maxQueueBytes = 4 * 1024 * 1024, int maxQueueLines = 1024,
      int maxWriteBytes = 4 * 1024 * 1024, int maxWriteCount = 256,
      int overflowWaitMs = 5000) {
    if (stdout == null) throw new ArgumentNullException("stdout");
    if (stdin == null) throw new ArgumentNullException("stdin");
    this.stdout = stdout;
    this.stdin = stdin;
    this.maxQueueBytes = Math.Max(256, maxQueueBytes);
    this.maxQueueLines = Math.Max(1, maxQueueLines);
    this.maxWriteBytes = Math.Max(256, maxWriteBytes);
    this.maxWriteCount = Math.Max(1, maxWriteCount);
    this.overflowWaitMs = Math.Max(100, overflowWaitMs);
    readerThread = new Thread(ReadLoop) { IsBackground = true, Name = "VTWorkerPipe.stdout" };
    writerThread = new Thread(WriteLoop) { IsBackground = true, Name = "VTWorkerPipe.stdin" };
    readerThread.Start();
    writerThread.Start();
  }

  public string LastError {
    get { lock (gate) { return lastError; } }
  }
  public bool IsEnded {
    get { lock (gate) { return eof; } }
  }
  public bool IsFaulted {
    get { lock (gate) { return faulted; } }
  }
  public int QueuedLines {
    get { lock (gate) { return lines.Count; } }
  }
  public long QueuedBytes {
    get { lock (gate) { return queuedLineBytes; } }
  }

  void ReadLoop() {
    try {
      string text;
      while ((text = stdout.ReadLine()) != null) {
        int bytes = Encoding.UTF8.GetByteCount(text) + 1;
        lock (gate) {
          while (!disposed && (lines.Count >= maxQueueLines || queuedLineBytes + bytes > maxQueueBytes)) {
            if (!Monitor.Wait(gate, overflowWaitMs)) {
              faulted = true;
              lastError = "worker stdout queue overflow: UI did not consume output in time";
              Monitor.PulseAll(gate);
              return;
            }
          }
          if (disposed) return;
          lines.Enqueue(new LineItem { Text = text, Bytes = bytes });
          queuedLineBytes += bytes;
          Monitor.PulseAll(gate);
        }
      }
      lock (gate) {
        eof = true;
        Monitor.PulseAll(gate);
      }
    } catch (Exception ex) {
      lock (gate) {
        if (!disposed) {
          faulted = true;
          lastError = "worker stdout read failed: " + ex.Message;
        }
        Monitor.PulseAll(gate);
      }
    }
  }

  // 0 = 取到一行；1 = 超时；2 = 子进程 stdout 已 EOF；3 = 读取/队列故障。
  public int ReadLine(int timeoutMs, out string line) {
    line = null;
    if (timeoutMs < 0) timeoutMs = 0;
    long deadline = timeoutMs == 0 ? 0 : Environment.TickCount64 + timeoutMs;
    lock (gate) {
      while (true) {
        if (lines.Count > 0) {
          LineItem item = lines.Dequeue();
          queuedLineBytes -= item.Bytes;
          if (queuedLineBytes < 0) queuedLineBytes = 0;
          line = item.Text;
          Monitor.PulseAll(gate);
          return 0;
        }
        if (faulted) return 3;
        if (eof) return 2;
        if (disposed) return 3;
        if (timeoutMs == 0) return 1;
        long remaining = deadline - Environment.TickCount64;
        if (remaining <= 0) return 1;
        Monitor.Wait(gate, (int)Math.Min(remaining, int.MaxValue));
      }
    }
  }

  public void WriteLine(string text, int timeoutMs) {
    if (text == null) throw new ArgumentNullException("text");
    if (timeoutMs < 1) timeoutMs = 1;
    byte[] data = Encoding.UTF8.GetBytes(text + "\n");
    WriteRequest req = new WriteRequest { Data = data };
    lock (gate) {
      if (disposed) throw new ObjectDisposedException("VTWorkerPipe");
      if (faulted) throw new IOException("worker stdin is unavailable: " + lastError);
      if (writes.Count >= maxWriteCount || queuedWriteBytes + data.Length > maxWriteBytes) {
        throw new InvalidOperationException("worker stdin queue is full");
      }
      writes.Enqueue(req);
      queuedWriteBytes += data.Length;
      Monitor.PulseAll(gate);
    }
    if (!req.Done.Wait(timeoutMs)) {
      lock (gate) {
        if (!faulted) {
          faulted = true;
          lastError = "worker stdin write timed out after " + timeoutMs + " ms";
          FailPendingLocked(new IOException(lastError));
          Monitor.PulseAll(gate);
        }
      }
      throw new TimeoutException("worker stdin write timed out after " + timeoutMs + " ms");
    }
    if (req.Error != null) {
      throw new IOException("worker stdin write failed: " + req.Error.Message, req.Error);
    }
  }

  void FailPendingLocked(Exception error) {
    while (writes.Count > 0) {
      WriteRequest pending = writes.Dequeue();
      pending.Error = error;
      pending.Done.Set();
    }
    queuedWriteBytes = 0;
  }

  void WriteLoop() {
    while (true) {
      WriteRequest req;
      lock (gate) {
        while (!disposed && !faulted && writes.Count == 0) Monitor.Wait(gate);
        if (disposed) return;
        if (faulted) {
          FailPendingLocked(new IOException("worker stdin is unavailable: " + lastError));
          return;
        }
        req = writes.Dequeue();
        queuedWriteBytes -= req.Data.Length;
        if (queuedWriteBytes < 0) queuedWriteBytes = 0;
      }
      try {
        stdin.Write(req.Data, 0, req.Data.Length);
        stdin.Flush();
      } catch (Exception ex) {
        req.Error = ex;
        lock (gate) {
          if (!disposed) {
            faulted = true;
            lastError = "worker stdin write failed: " + ex.Message;
            FailPendingLocked(new IOException(lastError));
          }
          Monitor.PulseAll(gate);
        }
        req.Done.Set();
        return;
      }
      req.Done.Set();
    }
  }

  public void Dispose() {
    Thread reader;
    Thread writer;
    lock (gate) {
      if (disposed) return;
      disposed = true;
      FailPendingLocked(new ObjectDisposedException("VTWorkerPipe"));
      lines.Clear();
      queuedLineBytes = 0;
      Monitor.PulseAll(gate);
      reader = readerThread;
      writer = writerThread;
    }
    try { stdin.Dispose(); } catch { }
    try { stdout.Dispose(); } catch { }
    try { if (reader != null) reader.Join(250); } catch { }
    try { if (writer != null) writer.Join(250); } catch { }
  }
}
'@
}

# 启动 worker 后立刻创建桥；之后所有 stdout/stdin 访问都必须经过它。
function New-WorkerPipe {
  param(
    [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
    [int]$MaxQueueBytes = 4 * 1024 * 1024,
    [int]$MaxQueueLines = 1024,
    [int]$MaxWriteBytes = 4 * 1024 * 1024,
    [int]$MaxWriteCount = 256,
    [int]$OverflowWaitMs = 5000
  )
  if (-not $Process) { throw 'worker 进程不存在' }
  return [VTWorkerPipe]::new($Process.StandardOutput, $Process.StandardInput.BaseStream,
    $MaxQueueBytes, $MaxQueueLines, $MaxWriteBytes, $MaxWriteCount, $OverflowWaitMs)
}

# 有界发送；超时/队列满/管道故障都会抛出明确异常，绝不无限等待 UI 线程。
function Send-WorkerLine {
  param([Parameter(Mandatory = $true)][string]$Line, [int]$TimeoutMs = 5000)
  if (-not $script:WorkerPipe) { throw 'worker 通信通道尚未建立' }
  $script:WorkerPipe.WriteLine($Line, $TimeoutMs)
}
