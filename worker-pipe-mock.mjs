// Offline mock worker for worker-pipe.test.ps1. No network, no credentials, synthetic JSONL only.
// Modes:
//   burst   - on start, synchronously emit many large result lines, then keep consuming stdin
//   stall   - do not read stdin for several seconds, to exercise the bounded write timeout
//   flood   - emit several lines larger than the bridge queue without stopping
//   exit    - exit shortly after ready, to exercise EOF/cleanup
//   delayed - emit one result after a delay, for restart isolation checks
//   finalexit   - finished (optionally preceded by a result), then exit after it is flushed
//   partialexit - one non-final result, then exit (no finished)
//   stale       - finished for an old session, then a result for the current session
//   normal  - result on start, finished on finish
import { createInterface } from 'node:readline';

const mode = process.env.VT_MOCK_MODE || 'normal';
const lineBytes = Math.max(1, Number(process.env.VT_MOCK_LINE_BYTES) || 70000);
const burstLines = Math.max(1, Number(process.env.VT_MOCK_BURST_LINES) || 10);
const delayMs = Math.max(0, Number(process.env.VT_MOCK_DELAY_MS) || 3000);
const preResult = process.env.VT_MOCK_PRE_RESULT === '1';

const write = event => process.stdout.write(JSON.stringify(event) + '\n');
const writeThenExit = event => process.stdout.write(JSON.stringify(event) + '\n', () => process.exit(0));
write({ event: 'ready' });

if (mode === 'exit') {
  setTimeout(() => process.exit(0), Math.max(50, delayMs));
}

let reader = null;
function attachReader() {
  if (reader) return;
  reader = createInterface({ input: process.stdin });
  reader.on('line', line => {
    let command;
    try { command = JSON.parse(line); } catch { return; }
    const session = command.session || 'mock-session';
    if (command.cmd === 'start') {
      if (mode === 'burst') {
        for (let i = 0; i < burstLines; i++) {
          write({ event: 'result', session, text: `r${i}-` + 'x'.repeat(lineBytes), segments: [], isFinal: false });
        }
      } else if (mode === 'flood') {
        for (let i = 0; i < burstLines; i++) {
          write({ event: 'result', session, text: `f${i}-` + 'x'.repeat(lineBytes), segments: [], isFinal: false });
        }
      } else if (mode === 'delayed') {
        setTimeout(() => write({ event: 'result', session, text: 'late-' + 'y'.repeat(lineBytes), segments: [] }), delayMs);
      } else if (mode === 'finalexit') {
        const finalText = 'final-exit-' + 'z'.repeat(lineBytes);
        if (preResult) {
          write({ event: 'result', session, text: 'pre-final-' + 'p'.repeat(lineBytes), segments: [], isFinal: false });
        }
        writeThenExit({
          event: 'finished', session, text: finalText, isFinal: true,
          segments: [{ start: 0, end: 1, text: finalText, definite: true }]
        });
      } else if (mode === 'partialexit') {
        writeThenExit({ event: 'result', session, text: 'partial-only', segments: [], isFinal: false });
      } else if (mode === 'stale') {
        write({ event: 'finished', session: 'stale-old-session', text: 'stale-old-final', segments: [], isFinal: true });
        write({ event: 'result', session, text: 'stale-new-result', segments: [] });
      } else if (mode === 'normal') {
        write({ event: 'result', session, text: 'hello', segments: [] });
      }
    } else if (command.cmd === 'finish') {
      write({ event: 'finished', session, text: 'final-' + 'z'.repeat(lineBytes), segments: [], isFinal: true });
    } else if (command.cmd === 'recognize') {
      write({ event: 'finished', session, text: 'hunyuan-ok', segments: [], durationMs: 1, tokens: 1 });
    } else if (command.cmd === 'exit') {
      process.exit(0);
    }
  });
}

if (mode === 'stall') {
  setTimeout(attachReader, 15000);
} else {
  attachReader();
}
