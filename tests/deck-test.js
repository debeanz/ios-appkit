#!/usr/bin/env node
// Tests src/WebHelperDeck.js (the Quick Access additions) on stub pages - no Steam code runs: the
// Performance messages it decodes and encodes (bytes worked out by hand from Steam's field
// numbers), System.Perf's callbacks, the Quick Access hook on a simulated menu (components found
// by the same text as in Steam's minified code, the Plugins tab added once, the Performance panel
// swapped with Steam's kept as its fallback) and user plugins loading or failing alone.
//
//   node tests/deck-test.js
"use strict";
const fs = require("fs"), vm = require("vm"), path = require("path");
const script = path.join(__dirname, "../src/WebHelperDeck.js");
process.argv[2] = script;
(function perfMessages() {
  const messages = [], timers = [];
  const win = {
    location: { pathname: '/index.html' }, opener: null,
    webkit: { messageHandlers: { steamclient: { postMessage: (m) => messages.push(m) } } },
    SteamClient: { System: { Audio: {} } },
    setTimeout: (f) => { timers.push(f); return 1; },
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
    Promise, Uint8Array, DataView, ArrayBuffer, BigInt, Symbol, Map, Set, Object, Array, JSON, Error, Function, String, Number, Math,
  };
  win.window = win;
  vm.createContext(win);
  vm.runInContext(fs.readFileSync(process.argv[2], 'utf8') + '\nakdeckInstall(window);', win);
  const assert = (c, what) => { if (!c) { console.log('FAIL', what); process.exitCode = 1; } else console.log('ok  ', what); };
  const Perf = win.SteamClient.System.Perf;
  assert(Perf && typeof Perf.UpdateSettings === 'function', 'System.Perf defined at document start');
  assert(win.SteamClient.System.Audio, 'existing System namespace kept');
  const update = Buffer.from([0x08, 0x81, 0x06, 0x1a, 0x04, 0x12, 0x02, 0x10, 0x1e]).toString('base64');
  Perf.UpdateSettings(update);
  const sent = messages.find((m) => m.name === 'perf-update');
  assert(sent && sent.args.gameid === '769' && sent.args.settings_delta.per_app.fps_limit === 30, 'UpdateSettings decoded: ' + JSON.stringify(sent && sent.args));
  const big = 18446744073709551615n;
  const bytes = [0x08];
  let n = big; do { let b = Number(n & 0x7fn); n >>= 7n; if (n) b |= 0x80; bytes.push(b); } while (n);
  bytes.push(0x10, 0x01, 0x1a, 0x06, 0x0a, 0x04, 0x28, 0x04, 0x38, 0x01);
  Perf.UpdateSettings(Buffer.from(bytes).toString('base64'));
  const sent2 = messages.filter((m) => m.name === 'perf-update')[1];
  assert(sent2 && sent2.args.gameid === big.toString() && sent2.args.reset_to_default === true &&
         sent2.args.settings_delta.global.perf_overlay_level === 4 && sent2.args.settings_delta.global.is_advanced_settings_enabled === true,
         'uint64, bool and nested global decoded: ' + JSON.stringify(sent2 && sent2.args));
  let got = null;
  const reg = Perf.RegisterForStateChanges((buf) => { got = new Uint8Array(buf); });
  const ask = messages.find((m) => m.name === 'perf-state');
  assert(ask && ask.id, 'state asked of the app');
  const state = { message: { current_game_id: '769', active_profile_game_id: '769',
    limits: { fps_limit_options: [15, 0], perf_overlay_is_standalone: false },
    settings: { global: { perf_overlay_level: 1 }, per_app: { fps_limit: 30, is_game_perf_profile_enabled: false } } }, app: {} };
  win.__akDeckReceive({ id: ask.id, v: state });
  setTimeout(() => {
    // Fields go out in field-number order within each message.
    const want = [0x0a, 0x06, 0x38, 0x00, 0x68, 0x0f, 0x68, 0x00, 0x12, 0x0a, 0x0a, 0x02, 0x28, 0x01, 0x12, 0x04, 0x10, 0x1e, 0x70, 0x00, 0x18, 0x81, 0x06, 0x20, 0x81, 0x06];
    assert(got && Buffer.from(got).equals(Buffer.from(want)), 'state encoded: ' + (got && Buffer.from(got).toString('hex')) + ' want ' + Buffer.from(want).toString('hex'));
    reg.unregister();
    got = null;
    win.__akDeckReceive({ ev: 'perf-state', a: [state] });
    assert(got === null, 'unregistered callback not called');
  }, 10);
  
})();
(function quickAccess() {
  const messages = [], timers = [];
  const React = {
    Component: class {}, PureComponent: class {}, useLayoutEffect() {}, useEffect() {}, useReducer: () => [0, () => {}], useState: (v) => [v, () => {}],
    Fragment: 'Fragment', createElement: (type, props, ...children) => ({ type, props: Object.assign({}, props, children.length ? { children: children.length === 1 ? children[0] : children } : {}) }),
  };
  const common = {};
  for (let i = 0; i < 62; i++) common['x' + i] = { dummy: i };
  common.ctx = { contextType: { _currentValue: {} } };
  common.toggle = { render: function () { return Se("ToggleField", $); } };
  common.slider = function E(Dt) { const lr = (0, f.Zt)("SliderField", v); return lr; };
  common.button = { render: new Function("p", "const{highlightOnFocus:R,childrenContainerWidth:Z}=p;return R") };
  common.dialogButton = { render: function () { return ["DialogButton","_DialogLayout","Secondary"]; } };
  common.dropdown = new Function("p", "const{dropDownControlRef:tn,description:Gi}=p;return tn");
  const Kt = [{ key: 4, title: 'settings', panel: 'settings-panel' }, { key: 5, title: 'perf', panel: 'steam-perf-panel' }, { key: 6, title: 'help' }];
  function q(props) { return React.createElement('nav', null, React.createElement('ye', { tabs: Kt }), React.createElement('ut', { tabs: Kt })); }
  const kt = { $$typeof: 'memo', type: function (Pt) { const x = "QuickAccessMenuBrowserView"; return React.createElement('portal', null, React.createElement(q, { onFocusNavDeactivated: () => {} })); } };
  const modules = {
    1: React,
    2: common,
    3: { F: function (e) { return [i().Field, "shift-children-below"]; }.bind ? function Fi(e) { return "().Field" + '"shift-children-below"'; } : null },
    4: { Z: new Function("p", "const{\"flow-children\":j,onActivate:y,onCancel:I,focusClassName:N,focusWithinClassName:x}=p;return j") },
    5: { a: function o(l) { return i().PanelSection; }, k: function u(l) { return 'row'; } },
    6: { Title: 'qam_title', QuickAccessMenu: 'qam' },
    7: { gv: function ee() { return "#QuickAccess_Tab_Perf_Overlay_Level"; }, mR: function we() { return "#QuickAccess_Tab_Perf_ToggleGameSettings"; },
         Mq: function pe() { return "#QuickAccess_Tab_Perf_LimitFrameRate"; }, jw: function le() { return "#QuickAccess_Tab_Perf_PerformanceSettings"; },
         DJ: function tt() { return "#QuickAccess_Tab_Perf_ResetToDefault"; } },
    8: { yC: function M() { return [R.bHasBattery, d().BatteryPercentageLabel, h.BatteryLarge]; } },
    9: { kt, embedded: { type: function () { return "QuickAccessMenuEmbedded"; } } },
  };
  modules[3] = { F: function Field() { const a = "().Field", b = "shift-children-below"; return '"shift-children-below"' + a + b; } };
  const req = (id) => modules[id];
  req.m = Object.fromEntries(Object.keys(modules).map((k) => [k, true]));
  req.c = Object.fromEntries(Object.keys(modules).map((k) => [k, { exports: modules[k] }]));
  const win = {
    location: { pathname: '/index.html' }, opener: null,
    webkit: { messageHandlers: { steamclient: { postMessage: (m) => messages.push(m) } } },
    SteamClient: { System: {} }, App: { BFinishedInitBeforeLogin: () => true },
    webpackChunksteamui: { push(entry) { entry[2](req); } },
    document: { getElementById: () => null },
    setTimeout: (f) => { timers.push(f); return 1; }, atob: (s) => Buffer.from(s, 'base64').toString('binary'),
    Promise, Uint8Array, DataView, ArrayBuffer, BigInt, Symbol, Map, Set, Object, Array, JSON, Error, Function, String, Number, Math, RegExp, encodeURIComponent,
  };
  win.window = win;
  vm.createContext(win);
  vm.runInContext(fs.readFileSync(process.argv[2], 'utf8') + '\nakdeckInstall(window);', win);
  for (let i = 0; i < 10 && timers.length; i++) for (const f of timers.splice(0)) f();
  const logs = messages.filter((m) => m.name === 'log').map((m) => m.args);
  console.log('logs:', logs);
  const assert = (c, what) => { console.log(c ? 'ok  ' : 'FAIL', what); if (!c) process.exitCode = 1; };
  for (let pass = 0; pass < 2; pass++) {
    const tree = kt.type({ visible: true });
    const qElement = tree.props.children;
    assert(qElement.type !== q, 'pass ' + pass + ': the menu body\'s component was patched');
    qElement.type(qElement.props);
  }
  assert(Kt.filter((t) => t.key === 1999).length === 1, 'Plugins tab added once (keys: ' + Kt.map((t) => t.key).join(',') + ')');
  const perf = Kt.find((t) => t.key === 5);
  assert(perf.__akdeck && perf.panel !== 'steam-perf-panel' && perf.panel.props.fallback === 'steam-perf-panel', 'Performance panel replaced, Steam\'s kept as the fallback');
  assert(win.AKPlugins && typeof win.AKPlugins.webpack.findModule === 'function', 'AKPlugins API exposed');
  assert(messages.some((m) => m.name === 'plugins'), 'user plugins asked for');
  const ask = messages.find((m) => m.name === 'plugins');
  win.__akDeckReceive({ id: ask.id, v: { folder: 'Documents/plugins', plugins: [
    { id: 'hello', name: 'Hello', enabled: true, main: 'index.js', source: 'const { PanelSection } = ui; plugin.log("hi"); return { name: "Hello!", Content: () => React.createElement(PanelSection, null) };' },
    { id: 'broken', name: 'Broken', enabled: true, main: 'index.js', source: 'throw new Error("nope")' },
    { id: 'off', name: 'Off', enabled: false },
  ] } });
  setTimeout(() => {
    const logs2 = messages.filter((m) => m.name === 'log').map((m) => String(m.args));
    assert(logs2.some((l) => l.includes('plugin hello loaded')), 'good plugin loaded');
    assert(logs2.some((l) => l.includes('[plugin hello] hi')), 'plugin.log reaches the app');
    assert(logs2.some((l) => l.includes('plugin broken failed to load') && l.includes('nope')), 'broken plugin reported, not fatal');
  }, 0);
  
})();
