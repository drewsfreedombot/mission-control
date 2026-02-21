const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = 3000;
const WORKSPACE = path.join(__dirname, '..');
const DASHBOARD = __dirname;

// ── Parsers ────────────────────────────────────────────────────────────────

function parseAgentTasks(md) {
  const sections = [];
  let currentSection = null;
  let currentTask = null;

  for (const line of md.split('\n')) {
    if (line.startsWith('## ')) {
      if (currentSection) sections.push(currentSection);
      const title = line.slice(3).trim();
      let status = 'info';
      if (title.includes('IN PROGRESS')) status = 'in-progress';
      else if (title.includes('WAITING')) status = 'waiting';
      else if (title.includes('COMPLETED')) status = 'completed';
      currentSection = { title, status, tasks: [] };
      currentTask = null;
    } else if (line.startsWith('### ') && currentSection) {
      currentTask = { name: line.slice(4).trim(), notes: [] };
      currentSection.tasks.push(currentTask);
    } else if (currentTask && line.trim().match(/^[-*•]/)) {
      currentTask.notes.push(line.trim().replace(/^[-*•]\s*/, ''));
    } else if (line.trim().match(/^-\s*(✅|⬜)/) && currentSection && !currentTask) {
      currentSection.tasks.push({ name: line.trim(), notes: [] });
    }
  }

  if (currentSection) sections.push(currentSection);
  return sections;
}

function parseCallAnalysis(content, filename) {
  const lines = content.split('\n');
  let contact = filename.replace('.md', '').replace(/_/g, ' ');
  let date = null;
  let business = null;
  const takeaways = [];

  for (const line of lines) {
    if (!date && line.match(/^Date:\s*/)) {
      date = line.replace(/^Date:\s*/, '').trim();
    }
    const callMatch = line.match(/^Call:\s*(.+)/);
    if (callMatch) contact = callMatch[1].trim();
    if (!business) {
      if (line.includes('Nmbr') || line.includes('Number')) business = 'Nmbr';
      else if (line.includes('Charlie')) business = 'Charlie';
    }
    if (
      line.match(/^[-*]\s*(MUST|Key|Takeaway|Action|✅|Follow)/i) &&
      takeaways.length < 4
    ) {
      takeaways.push(line.replace(/^[-*]\s*/, '').trim());
    }
  }

  if (!date) {
    const m = filename.match(/(\d{4}-\d{2}-\d{2})/);
    if (m) date = m[1];
  }

  return { contact, date: date || 'Unknown', business: business || 'Unknown', takeaways, filename };
}

// ── MIME types ─────────────────────────────────────────────────────────────

const MIME = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.json': 'application/json',
  '.ico': 'image/x-icon',
};

// ── Request handler ────────────────────────────────────────────────────────

const server = http.createServer((req, res) => {
  const parsed = url.parse(req.url, true);
  const pathname = parsed.pathname;

  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  const json = (code, data) => {
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(data));
  };

  // GET /api/agent-tasks
  if (pathname === '/api/agent-tasks' && req.method === 'GET') {
    fs.readFile(path.join(WORKSPACE, 'memory', 'active-tasks.md'), 'utf8', (err, data) => {
      if (err) return json(200, { sections: [], error: 'active-tasks.md not found' });
      json(200, { sections: parseAgentTasks(data), updatedAt: new Date().toISOString() });
    });
    return;
  }

  // GET /api/call-analyses
  if (pathname === '/api/call-analyses' && req.method === 'GET') {
    const dir = path.join(WORKSPACE, 'memory', 'call-analyses');
    fs.mkdir(dir, { recursive: true }, () => {
      fs.readdir(dir, (err, files) => {
        if (err || !files) return json(200, { analyses: [] });
        const mdFiles = files.filter(f => f.endsWith('.md')).sort().reverse();
        if (!mdFiles.length) return json(200, { analyses: [] });
        const analyses = [];
        let pending = mdFiles.length;
        mdFiles.forEach(filename => {
          fs.readFile(path.join(dir, filename), 'utf8', (err, content) => {
            if (!err) {
              analyses.push({
                ...parseCallAnalysis(content, filename),
                filePath: path.join(dir, filename),
              });
            }
            if (--pending === 0) json(200, { analyses });
          });
        });
      });
    });
    return;
  }

  // GET /api/docs  POST /api/docs
  if (pathname === '/api/docs') {
    const docsPath = path.join(DASHBOARD, 'docs.json');
    if (req.method === 'GET') {
      fs.readFile(docsPath, 'utf8', (err, data) => {
        if (err) return json(200, { docs: [] });
        try { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(data); }
        catch { json(200, { docs: [] }); }
      });
    } else if (req.method === 'POST') {
      let body = '';
      req.on('data', c => body += c);
      req.on('end', () => {
        try {
          const payload = JSON.parse(body);
          fs.writeFile(docsPath, JSON.stringify(payload, null, 2), err =>
            err ? json(500, { error: 'Write failed' }) : json(200, { success: true })
          );
        } catch { json(400, { error: 'Bad JSON' }); }
      });
    }
    return;
  }

  // GET /api/file  – read a file by absolute path (within workspace only)
  if (pathname === '/api/file' && req.method === 'GET') {
    const filePath = parsed.query.path;
    if (!filePath || !filePath.startsWith(WORKSPACE)) return json(403, { error: 'Forbidden' });
    fs.readFile(filePath, 'utf8', (err, data) => {
      if (err) return json(404, { error: 'Not found' });
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end(data);
    });
    return;
  }

  // Static files
  const filePath = path.join(DASHBOARD, pathname === '/' ? 'index.html' : pathname);
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end('Not found'); return; }
    const ext = path.extname(filePath);
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`\n🦅 Freedom Mission Control\n   http://localhost:${PORT}\n`);
});
