// Prueba ONLINE de la versión web: host + N clientes en pestañas de Chromium (Playwright), con salas por
// código (WebRTC) y un servidor PeerJS local en vez del público.
//
// Uso (desde la raíz del proyecto, con la exportación web en build/web):
//   tests/web/serve.sh                         # sirve build/web con argumentos por URL + PeerJS local
//   node tests/web/online_test.js [clientes] [minijuegos] [id_minijuego]
// Sale con 0 si host y clientes llegan a la pantalla final con las mismas puntuaciones.
const { chromium } = require('playwright');
const N = parseInt(process.argv[2] || '2');
const GAMES = parseInt(process.argv[3] || '2');
const ONLY = process.argv[4] ? ` --only=${process.argv[4]}` : '';
const URL = process.env.WEB_URL || 'http://localhost:8765/index.html';
const COMMON = ' --signal=ws://127.0.0.1:9000 --log --autopilot --timescale=2';

(async () => {
  const browser = await chromium.launch({ args: ['--disable-features=WebRtcHideLocalIpsWithMdns'] });
  const logs = {};
  const t0 = Date.now();
  const open = async (name, args) => {
    const page = await (await browser.newContext()).newPage();
    logs[name] = [];
    page.on('console', m => {
      const t = m.text();
      logs[name].push(t);
      if (/\[EVT\] (?!audio|roster)/.test(t)) console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s ${name}] ${t}`);
    });
    await page.goto(URL + '?args=' + encodeURIComponent(args + COMMON));
  };
  const wait = async (name, re, ms) => {
    for (const end = Date.now() + ms; Date.now() < end; await new Promise(r => setTimeout(r, 250))) {
      const hit = logs[name].find(l => re.test(l));
      if (hit) return hit;
    }
    return null;
  };
  const fail = async msg => { console.log('FALLO: ' + msg); await browser.close(); process.exit(1); };

  await open('host', `--host --name=Host --players=${N + 1} --games=${GAMES}${ONLY}`);
  const opened = await wait('host', /room_open code=(\w+)/, 60000);
  if (!opened) await fail('la sala no se abrió');
  const code = opened.match(/code=(\w+)/)[1];
  for (let i = 1; i <= N; i++) await open('c' + i, `--join=${code} --name=Cli${i}`);
  if (!(await wait('host', /state=INTRO/, 90000))) await fail('la partida no empezó');
  const final = await wait('host', /final scores=/, 900000);
  if (!final) await fail('el host no llegó al final');
  for (let i = 1; i <= N; i++) {
    const f = await wait('c' + i, /final scores=/, 30000);
    if (!f || f.split('final scores=')[1] !== final.split('final scores=')[1]) await fail(`c${i} no coincide: ${f}`);
  }
  console.log('OK: ' + final);
  await browser.close();
})();
