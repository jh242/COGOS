const http = require('http');
const { spawn } = require('child_process');

const PORT = process.env.PORT || 9090;
const RELAY_SECRET = process.env.RELAY_SECRET || '';
const RELAY_CWD = process.env.RELAY_CWD || undefined;  // intentional: empty string treated as unset

const server = http.createServer((req, res) => {
  if (req.method !== 'POST' || req.url !== '/query') {
    res.writeHead(404);
    res.end();
    return;
  }

  if (RELAY_SECRET) {
    const auth = req.headers['authorization'] || '';
    if (auth !== `Bearer ${RELAY_SECRET}`) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Unauthorized' }));
      return;
    }
  }

  const MAX_BODY = 1024 * 64; // 64 KB — ample for any voice query
  let body = '';
  req.on('data', (chunk) => {
    body += chunk;
    if (body.length > MAX_BODY) {
      res.writeHead(413, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Request too large' }));
      req.destroy();
    }
  });
  req.on('end', () => {
    if (res.writableEnded) return; // already rejected above
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch (e) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
      return;
    }

    const { message, session_id } = parsed;
    if (!message) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Missing message' }));
      return;
    }

    const args = ['-p', '--output-format', 'stream-json'];
    if (session_id) {
      args.push('--resume', session_id);
    }

    const child = spawn('claude', args, {
      cwd: RELAY_CWD,
      env: process.env,
    });

    child.stdin.write(message);
    child.stdin.end();

    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      'Access-Control-Allow-Origin': '*',
    });

    let stdoutBuf = '';
    let childAlive = true;

    function processLines(flush = false) {
      const lines = stdoutBuf.split('\n');
      // On flush consume everything; otherwise hold the last element as a partial line.
      stdoutBuf = flush ? '' : lines.pop();
      for (const line of lines) {
        if (!line.trim()) continue;
        let event;
        try {
          event = JSON.parse(line);
        } catch (e) {
          continue;
        }

        if (event.type === 'assistant' && Array.isArray(event.message?.content)) {
          for (const block of event.message.content) {
            if (block.type === 'text' && block.text) {
              res.write(`data: ${JSON.stringify({ type: 'text', text: block.text })}\n\n`);
            }
          }
        } else if (event.type === 'result' && event.session_id) {
          res.write(`data: ${JSON.stringify({ type: 'done', session_id: event.session_id })}\n\n`);
        }
      }
    }

    child.stdout.on('data', (chunk) => {
      stdoutBuf += chunk.toString();
      processLines();
    });

    child.stderr.on('data', (chunk) => {
      console.error('claude stderr:', chunk.toString());
    });

    child.on('close', (code) => {
      childAlive = false;
      // Flush any partial line that arrived without a trailing newline.
      if (stdoutBuf.trim()) processLines(true);
      if (code !== 0) {
        res.write(`data: ${JSON.stringify({ type: 'error', message: `claude exited with code ${code}` })}\n\n`);
      }
      res.end();
    });

    child.on('error', (err) => {
      childAlive = false;
      res.write(`data: ${JSON.stringify({ type: 'error', message: err.message })}\n\n`);
      res.end();
    });

    req.on('close', () => {
      if (childAlive) child.kill();
    });
  });
});

server.listen(PORT, () => {
  console.log(`Relay server listening on port ${PORT}`);
});
