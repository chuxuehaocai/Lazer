// A real JS client connects to the real Lua VM, not a mocked bridge.
const {LazerClient} = require('../../examples/lua-frontend/frontend/client.js');
const readline = require('node:readline');
const fs = require('node:fs');
const vm = require('node:vm');
const client = new LazerClient();

// Exercise the shipped application renderer as well as its transport, with a
// tiny DOM double. All backend responses still cross the real WebSocket/Lua
// bridge. This catches Lua's empty-table representation and field mismatches.
async function renderApplication(command) {
  class Element {
    constructor() {
      this.textContent = ''; this.value = ''; this.children = [];
      this.offsetTop = 0; this.scrollTop = 0;
      const classes = new Set();
      this.classList = {contains: key => classes.has(key), toggle: (key, on) => on ? classes.add(key) : classes.delete(key)};
    }
    addEventListener() {}
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this.children = children; }
    getAttribute(key) { return this[key]; }
    removeAttribute(key) { delete this[key]; }
  }
  const elements = new Map();
  const document = {
    getElementById(id) { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); },
    createElement() { return new Element(); },
    querySelectorAll() { return []; },
    activeElement: null, hidden: false,
  };
  const context = vm.createContext({
    LazerClient, document, window: {addEventListener() {}}, setInterval() {},
    __address: command.url, __token: command.token,
  });
  vm.runInContext(fs.readFileSync(require.resolve('../../examples/lua-frontend/frontend/app.js'), 'utf8'), context);
  try {
    await vm.runInContext('client.connect(__address, __token).then(refresh)', context);
    return {title: elements.get('now-title').textContent, queueRows: elements.get('queue').children.length,
      lyricRows: elements.get('lyrics').children.length, time: elements.get('time').textContent};
  } finally {
    vm.runInContext('client.close()', context);
  }
}
(async () => {
  for await (const line of readline.createInterface({input: process.stdin})) {
    try {
      const command = JSON.parse(line);
      let value;
      if (command.operation === 'render') value = await renderApplication(command);
      else if (command.operation === 'connect') value = await client.connect(command.url, command.token);
      else if (command.operation === 'close') { client.close(); value = true; }
      else value = await client.request(command.method, command.args);
      process.stdout.write(JSON.stringify({ok: true, value}) + '\n');
    } catch (error) {
      process.stdout.write(JSON.stringify({ok: false, error: error.message}) + '\n');
    }
  }
  client.close();
})().catch(() => { client.close(); process.exitCode = 1; });
