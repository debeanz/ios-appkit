// Steam's Quick Access menu, finished for a phone, the way Decky Loader finishes it on Steam Deck.
// WebHelperWeb.m injects this into Steam's interface page (the shared context that runs all of
// Steam's React code; compiled into WebHelperDeck.inc by tools/gen-bridge.js) right after the
// SteamClient bridge, at document start. It:
//  - is SteamClient.System.Perf, which Steam's Mac client lacks: Steam's own Performance tab (the
//    Deck's: overlay level, per-game profile, frame rate limit) reads and changes the state it
//    reports, and the app (GameProfiles.m) applies it to the running game - the overlay level is
//    Apple's Metal HUD;
//  - puts that tab's Deck layout in the Quick Access menu, with the app's own resolution row;
//  - adds a Plugins tab, as Decky's is: built-in plugins (Display, Logs) and the user's own from
//    Documents/plugins (see the README the app writes there), each opened from the list.
// How it reaches Steam's interface is Decky's: webpack's module cache searched by what the
// modules contain (@decky/ui webpack.ts), functions patched in place (patcher.ts), React trees
// searched and the Quick Access menu's renderer patched to add tabs (decky-loader tabs-hook.tsx,
// @decky/ui react.ts and treepatcher.ts), and Steam's own components found the same way.
function akdeckInstall(win) {
  'use strict';
  if (win.__akDeck) return;
  try {
    if (win.opener || win.location.pathname !== '/index.html') return;
  } catch (e) {
    return;
  }
  const handler = win.webkit && win.webkit.messageHandlers && win.webkit.messageHandlers.steamclient;
  if (!handler) return;
  Object.defineProperty(win, '__akDeck', { value: true });

  // --- The app ---

  const pending = new Map();
  let nextCall = 1;
  const listeners = new Map();
  const call = (name, args) => new win.Promise((resolve) => {
    const id = nextCall++;
    pending.set(id, resolve);
    handler.postMessage({ op: 'deck', name, args: args === undefined ? null : args, id });
  });
  const tell = (name, args) => handler.postMessage({ op: 'deck', name, args: args === undefined ? null : args });
  const on = (event, fn) => {
    if (!listeners.has(event)) listeners.set(event, new Set());
    listeners.get(event).add(fn);
    return () => listeners.get(event).delete(fn);
  };
  const describe = (v) => {
    if (typeof v === 'string') return v;
    if (v && v.stack) return String(v.stack);
    try { return JSON.stringify(v); } catch (e) { return String(v); }
  };
  const log = (...parts) => tell('log', parts.map(describe).join(' '));
  const report = (what, e) => log(what + ': ' + describe(e));
  Object.defineProperty(win, '__akDeckReceive', {
    value(m) {
      if (m.id) {
        const resolve = pending.get(m.id);
        pending.delete(m.id);
        if (resolve) resolve(m.v);
        return;
      }
      const set = listeners.get(m.ev);
      if (set) for (const fn of Array.from(set)) { try { fn.apply(null, m.a || []); } catch (e) { report('event ' + m.ev, e); } }
    },
  });

  // --- Steam's Performance messages ---
  // CMsgSystemPerfState and friends, with the field numbers Steam's own code gives them (its
  // module defining the classes whose getClassName() is "CMsgSystemPerf..."). Encoded and decoded
  // here so nothing waits for Steam's classes to be found.
  const MESSAGES = {
    State: { 1: ['limits', 'Limits'], 2: ['settings', 'Settings'], 3: ['current_game_id', 'uint64'], 4: ['active_profile_game_id', 'uint64'] },
    Update: { 1: ['gameid', 'uint64'], 2: ['reset_to_default', 'bool'], 3: ['settings_delta', 'Settings'], 4: ['skip_storage_update', 'bool'] },
    Settings: { 1: ['global', 'Global'], 2: ['per_app', 'PerApp'] },
    Limits: {
      1: ['cpu_governor_manual_min_mhz', 'int32'], 2: ['cpu_governor_manual_max_mhz', 'int32'], 3: ['fsr_sharpness_min', 'int32'],
      4: ['fsr_sharpness_max', 'int32'], 7: ['perf_overlay_is_standalone', 'bool'], 9: ['is_manual_display_refresh_rate_available', 'bool'],
      11: ['display_refresh_manual_hz_min', 'int32'], 12: ['display_refresh_manual_hz_max', 'int32'], 13: ['fps_limit_options', 'int32*'],
      14: ['tdp_limit_min', 'int32'], 15: ['tdp_limit_max', 'int32'], 19: ['display_external_refresh_manual_hz_min', 'int32'],
      20: ['display_external_refresh_manual_hz_max', 'int32'], 21: ['fps_limit_options_external', 'int32*'], 23: ['is_vrr_supported', 'bool'],
      24: ['is_dynamic_refresh_rate_in_steam_supported', 'bool'], 26: ['split_scaling_filters_available', 'enum*'],
      27: ['split_scaling_scalers_available', 'enum*'], 30: ['disable_refresh_rate_management', 'bool'],
    },
    Global: {
      1: ['diagnostic_update_rate', 'float'], 3: ['graphics_profiling_service_state', 'enum'], 4: ['perf_overlay_service_state', 'enum'],
      5: ['perf_overlay_level', 'enum'], 6: ['is_show_perf_overlay_over_steam_enabled', 'bool'], 7: ['is_advanced_settings_enabled', 'bool'],
      8: ['allow_external_display_refresh_control', 'bool'], 12: ['hdr_on_sdr_tonemap_operator', 'enum'], 13: ['is_hdr_debug_heatmap_enabled', 'bool'],
      21: ['is_color_management_enabled', 'bool'], 22: ['sdr_to_hdr_brightness', 'float'],
    },
    PerApp: {
      2: ['fps_limit', 'int32'], 3: ['is_variable_resolution_enabled', 'bool'], 4: ['is_dynamic_refresh_rate_enabled', 'bool'],
      5: ['tdp_limit', 'int32'], 6: ['cpu_governor', 'enum'], 7: ['cpu_governor_manual_mhz', 'int32'], 8: ['scaling_filter', 'int32'],
      9: ['fsr_sharpness', 'int32'], 10: ['is_fps_limit_enabled', 'bool'], 11: ['is_tdp_limit_enabled', 'bool'],
      12: ['is_low_latency_mode_enabled', 'bool'], 13: ['display_refresh_manual_hz', 'int32'], 14: ['is_game_perf_profile_enabled', 'bool'],
      17: ['display_external_refresh_manual_hz', 'int32'], 18: ['fps_limit_external', 'int32'], 19: ['is_tearing_enabled', 'bool'],
      20: ['is_vrr_enabled', 'bool'], 23: ['use_dynamic_refresh_rate_in_steam', 'bool'], 24: ['split_scaling_filter', 'enum'],
      25: ['split_scaling_scaler', 'enum'],
    },
  };

  function encode(type, obj) {
    const out = [];
    const varint = (v) => {
      let n = BigInt.asUintN(64, BigInt(v));
      do {
        let byte = Number(n & 0x7fn);
        n >>= 7n;
        if (n) byte |= 0x80;
        out.push(byte);
      } while (n);
    };
    const key = (field, wire) => varint((field << 3) | wire);
    const fields = MESSAGES[type];
    for (const number of Object.keys(fields)) {
      const [name, kind] = fields[number];
      const value = obj ? obj[name] : undefined;
      if (value === undefined || value === null) continue;
      const field = Number(number);
      const one = (v) => {
        const k = kind.replace('*', '');
        if (MESSAGES[k]) {
          const bytes = encode(k, v);
          key(field, 2);
          varint(bytes.length);
          for (const b of bytes) out.push(b);
        } else if (k === 'float') {
          key(field, 5);
          const view = new DataView(new ArrayBuffer(4));
          view.setFloat32(0, Number(v), true);
          for (let i = 0; i < 4; i++) out.push(view.getUint8(i));
        } else if (k === 'bool') {
          key(field, 0);
          varint(v ? 1 : 0);
        } else if (k === 'uint64') {
          key(field, 0);
          varint(BigInt(String(v)));
        } else {
          key(field, 0);
          varint(Math.trunc(Number(v)));
        }
      };
      if (kind.endsWith('*')) { for (const v of value) one(v); } else one(value);
    }
    return out;
  }

  function decode(type, bytes) {
    const fields = MESSAGES[type];
    const obj = {};
    let i = 0;
    const varint = () => {
      let n = 0n, shift = 0n;
      for (;;) {
        if (i >= bytes.length) throw new Error('truncated ' + type);
        const b = bytes[i++];
        n |= BigInt(b & 0x7f) << shift;
        if (!(b & 0x80)) return n;
        shift += 7n;
      }
    };
    const scalar = (kind, n) => {
      if (kind === 'uint64') return BigInt.asUintN(64, n).toString();
      if (kind === 'bool') return n !== 0n;
      return Number(BigInt.asIntN(32, n));
    };
    while (i < bytes.length) {
      const tag = Number(varint());
      const field = tag >>> 3, wire = tag & 7;
      const spec = fields[field];
      const kind = spec ? spec[1].replace('*', '') : null;
      const repeated = spec && spec[1].endsWith('*');
      const put = (v) => {
        if (!spec) return;
        if (repeated) (obj[spec[0]] = obj[spec[0]] || []).push(v);
        else obj[spec[0]] = v;
      };
      if (wire === 0) {
        put(scalar(kind, varint()));
      } else if (wire === 1) {
        i += 8;
      } else if (wire === 2) {
        const length = Number(varint());
        const body = bytes.subarray(i, i + length);
        i += length;
        if (kind && MESSAGES[kind]) {
          put(decode(kind, body));
        } else if (repeated) {
          // Packed repeated numbers.
          for (let j = 0; j < body.length;) {
            let n = 0n, shift = 0n;
            for (;;) { const b = body[j++]; n |= BigInt(b & 0x7f) << shift; if (!(b & 0x80) || j >= body.length) break; shift += 7n; }
            put(scalar(kind, n));
          }
        }
      } else if (wire === 5) {
        const view = new DataView(bytes.buffer, bytes.byteOffset + i, 4);
        i += 4;
        put(view.getFloat32(0, true));
      } else {
        throw new Error('unexpected wire type ' + wire + ' in ' + type);
      }
    }
    return obj;
  }

  const base64Bytes = (s) => {
    const bin = win.atob(s);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  };

  // --- SteamClient.System.Perf ---
  // Steam's SystemPerfStore registers for the state and sends each change as base64
  // CMsgSystemPerfUpdateSettings; the app answers each with the new state.
  const perf = { message: null, app: {}, callbacks: new Set(), asked: false, watchers: new Set() };
  function deliver(cb) {
    if (!perf.message) return;
    const bytes = Uint8Array.from(encode('State', perf.message));
    try { cb(bytes.buffer); } catch (e) { report('Steam\'s performance state handler', e); }
  }
  function takeState(state) {
    if (!state || !state.message) return;
    perf.message = state.message;
    perf.app = state.app || {};
    for (const cb of Array.from(perf.callbacks)) deliver(cb);
    for (const fn of Array.from(perf.watchers)) { try { fn(); } catch (e) { report('performance watcher', e); } }
  }
  const askState = () => {
    if (perf.asked) return;
    perf.asked = true;
    call('perf-state').then(takeState);
  };
  on('perf-state', takeState);
  const SteamClient = win.SteamClient || (win.SteamClient = {});
  SteamClient.System = SteamClient.System || {};
  if (!SteamClient.System.Perf) {
    SteamClient.System.Perf = {
      RegisterForStateChanges(callback) {
        if (typeof callback !== 'function') throw new Error('Client methods registered as callbacks require the last param to be a function');
        perf.callbacks.add(callback);
        if (perf.message) win.setTimeout(() => { if (perf.callbacks.has(callback)) deliver(callback); }, 0);
        askState();
        return { unregister() { perf.callbacks.delete(callback); } };
      },
      RegisterForDiagnosticInfoChanges(callback) {
        return { unregister() {} };
      },
      UpdateSettings(base64) {
        try {
          const update = decode('Update', base64Bytes(String(base64)));
          call('perf-update', update).then(takeState);
        } catch (e) {
          report('performance settings update', e);
        }
      },
    };
  }

  // --- Steam's modules (webpack) ---
  let webpackRequire = null, everyModule = null;
  const requireFn = () => {
    if (webpackRequire) return webpackRequire;
    const chunks = win.webpackChunksteamui;
    if (!chunks || typeof chunks.push !== 'function') return null;
    chunks.push([[Symbol('akdeck')], {}, (r) => { webpackRequire = r; }]);
    return webpackRequire;
  };
  // The modules loaded so far; once something isn't among them, every module, loaded once (as
  // @decky/ui does from the start: a module's side effects run as it loads, failures don't matter).
  function moduleList() {
    const req = requireFn();
    if (!req) return [];
    if (everyModule) return everyModule;
    return Object.values(req.c || {}).map((entry) => entry && entry.exports).filter(Boolean);
  }
  function search(fn) {
    let found = fn(moduleList());
    const req = requireFn();
    if (found === undefined && !everyModule && req) {
      everyModule = [];
      for (const id of Object.keys(req.m)) { try { const m = req(id); if (m) everyModule.push(m); } catch (e) {} }
      found = fn(everyModule);
    }
    return found;
  }
  const findModule = (filter) => search((list) => {
    for (const m of list) {
      try {
        if (m.default && filter(m.default)) return m.default;
        if (filter(m)) return m;
      } catch (e) {}
    }
    return undefined;
  });
  const findModuleDetailsByExport = (filter, minExports) => search((list) => {
    for (const m of list) {
      for (const mod of [m.default, m]) {
        if (!mod || typeof mod !== 'object' || mod === win) continue;
        if (minExports && Object.keys(mod).length < minExports) continue;
        for (const name in mod) {
          let value;
          try { value = mod[name]; } catch (e) { continue; }
          if (!value) continue;
          try { if (filter(value, name)) return [mod, value, name]; } catch (e) {}
        }
      }
    }
    return undefined;
  }) || [];
  const findModuleByExport = (filter, minExports) => findModuleDetailsByExport(filter, minExports)[0];
  const findModuleExport = (filter, minExports) => findModuleDetailsByExport(filter, minExports)[1];
  const source = (fn) => { try { return typeof fn === 'function' ? Function.prototype.toString.call(fn) : ''; } catch (e) { return ''; } };
  const functionIncludes = (...texts) => findModuleExport((e) => typeof e === 'function' && texts.every((t) => source(e).includes(t)));

  // --- Patching, as @decky/ui's patcher ---
  function afterPatch(object, property, patchHandler) {
    const original = object[property];
    const patch = { original, object, property };
    object[property] = function () {
      const args = Array.from(arguments);
      const ret = patch.original.apply(this, args);
      return patchHandler.call(this, args, ret);
    };
    Object.assign(object[property], original);
    object[property].toString = () => source(original);
    object[property].__akdeckPatch = patch;
    patch.unpatch = () => { if (object[property] && object[property].__akdeckPatch === patch) object[property] = original; };
    return patch;
  }
  function beforePatch(object, property, patchHandler) {
    const original = object[property];
    const patch = { original, object, property };
    object[property] = function () {
      const args = Array.from(arguments);
      patchHandler.call(this, args);
      return patch.original.apply(this, args);
    };
    Object.assign(object[property], original);
    object[property].toString = () => source(original);
    object[property].__akdeckPatch = patch;
    patch.unpatch = () => { if (object[property] && object[property].__akdeckPatch === patch) object[property] = original; };
    return patch;
  }
  const callOriginal = Symbol('akdeck call original');
  function replacePatch(object, property, patchHandler) {
    const original = object[property];
    const patch = { original, object, property };
    object[property] = function () {
      const args = Array.from(arguments);
      const ret = patchHandler.call(this, args);
      return ret === callOriginal ? patch.original.apply(this, args) : ret;
    };
    Object.assign(object[property], original);
    object[property].toString = () => source(original);
    object[property].__akdeckPatch = patch;
    patch.unpatch = () => { if (object[property] && object[property].__akdeckPatch === patch) object[property] = original; };
    return patch;
  }

  // --- React trees, as @decky/ui's react.ts and treepatcher.ts ---
  function findInTree(parent, filter, walkable) {
    const seen = new Set();
    const walk = (node) => {
      if (!node || typeof node !== 'object' || seen.has(node)) return null;
      seen.add(node);
      if (filter(node)) return node;
      if (Array.isArray(node)) {
        for (const item of node) { const found = walk(item); if (found) return found; }
        return null;
      }
      for (const key of walkable || Object.keys(node)) {
        let child;
        try { child = node[key]; } catch (e) { continue; }
        const found = walk(child);
        if (found) return found;
      }
      return null;
    };
    try { return walk(parent); } catch (e) { return null; }
  }
  const findInReactTree = (node, filter) => findInTree(node, (n) => { try { return filter(n); } catch (e) { return false; } },
                                                       ['props', 'children', 'child', 'sibling']);
  function getReactRoot(element) {
    if (!element) return null;
    const key = Object.keys(element).find((k) => k.startsWith('__reactContainer$'));
    return (key && element[key]) || (element._reactRootContainer && element._reactRootContainer._internalRoot &&
                                      element._reactRootContainer._internalRoot.current) || null;
  }
  // Patches the components a render step finds in the tree (each step's node, then the next
  // step inside what that node renders), caching the patched type per original so a component
  // is wrapped once however often it renders.
  function createReactTreePatcher(steps, patchHandler) {
    const caches = [];
    const stepHandler = (step) => (args, tree) => {
      const cache = caches[step] || (caches[step] = new Map());
      const node = steps[step](tree);
      if (!node || !node.type) return tree;
      const cached = cache.get(node.type);
      if (cached) { node.type = cached; return tree; }
      const originalType = node.type;
      const next = steps[step + 1] ? stepHandler(step + 1) : patchHandler;
      patchNode(node, 'type', next);
      cache.set(originalType, node.type);
      return tree;
    };
    const patchNode = (node, prop, next) => {
      const type = node[prop];
      if (typeof type === 'function') {
        if (type.prototype && type.prototype.render) {
          const wrapped = class extends type {};
          node[prop] = wrapped;
          afterPatch(wrapped.prototype, 'render', next);
        } else {
          afterPatch(node, prop, next);
        }
      } else if (type && typeof type === 'object') {
        node[prop] = Object.assign({}, type);   // a memo or forwardRef: wrapped, the original untouched
        patchNode(node[prop], node[prop].render ? 'render' : 'type', next);
      }
    };
    return stepHandler(0);
  }

  // --- Steam's React and components ---
  let React = null, h = null;
  const ui = {};
  const createPropListRegex = (props, fromStart) =>
    new RegExp((fromStart ? 'const\\{' : '') + props.map((p) => '"?' + p + '"?:[a-zA-Z_$]{1,2}').join(','));
  function findComponents() {
    React = win.SP_REACT || findModule((m) => m.Component && m.PureComponent && m.useLayoutEffect);
    if (!React) return false;
    h = React.createElement;
    const common = findModule((m) => {
      if (typeof m !== 'object') return false;
      for (const p in m) { if (m[p] && m[p].contextType && m[p].contextType._currentValue && Object.keys(m).length > 60) return true; }
      return false;
    });
    const parts = common ? Object.values(common) : [];
    const renderSource = (c) => (c && c.render ? source(c.render) : '');
    const buttonItem = createPropListRegex(['highlightOnFocus', 'childrenContainerWidth'], false);
    const dropdownItem = createPropListRegex(['dropDownControlRef', 'description'], false);
    const focusable = createPropListRegex(['flow-children', 'onActivate', 'onCancel', 'focusClassName', 'focusWithinClassName'], true);
    ui.ToggleField = parts.find((c) => renderSource(c).includes('ToggleField",'));
    ui.SliderField = parts.find((c) => source(c).includes('SliderField",'));
    ui.ButtonItem = parts.find((c) => buttonItem.test(renderSource(c)) || renderSource(c).includes('childrenContainerWidth:"min"'));
    ui.DialogButton = parts.find((c) => renderSource(c).includes('"DialogButton","_DialogLayout","Secondary"'));
    ui.DropdownItem = parts.find((c) => dropdownItem.test(source(c)));
    ui.Field = findModuleExport((e) => (source(e).includes('().Field') && source(e).includes('"shift-children-below"')) ||
                                       (e && e.render && source(e.render).includes('"shift-children-below"')));
    ui.Focusable = findModuleExport((e) => (typeof e === 'function' && focusable.test(source(e))) || (e && e.render && focusable.test(source(e.render))));
    const [panelModule, panelSection] = findModuleDetailsByExport((e) => source(e).includes('.PanelSection'));
    ui.PanelSection = panelSection;
    ui.PanelSectionRow = panelModule && Object.values(panelModule).find((e) => e && !source(e).includes('.PanelSection'));
    ui.qamClasses = findModule((m) => typeof m.Title === 'string' && typeof m.QuickAccessMenu === 'string') || {};
    const missing = ['ToggleField', 'SliderField', 'ButtonItem', 'DialogButton', 'DropdownItem', 'Field', 'Focusable', 'PanelSection', 'PanelSectionRow']
      .filter((name) => !ui[name]);
    if (missing.length) log('Steam components not found: ' + missing.join(', '));
    return true;
  }
  // What each tab needs of them.
  const canShowPerformance = () => perfRowsFound && ui.PanelSection && ui.PanelSectionRow;
  const canShowPlugins = () => ['ButtonItem', 'PanelSection', 'PanelSectionRow', 'ToggleField', 'SliderField'].every((n) => ui[n]);

  // Steam's own rows of the Deck's Performance tab, by what each shows (the localization keys).
  const perfRows = {};
  function findPerfRows() {
    perfRows.battery = functionIncludes('bHasBattery', 'BatteryPercentageLabel', '.BatteryLarge');
    perfRows.overlayLevel = functionIncludes('"#QuickAccess_Tab_Perf_Overlay_Level"');
    perfRows.header = functionIncludes('"#QuickAccess_Tab_Perf_PerformanceSettings"');
    perfRows.perGame = functionIncludes('"#QuickAccess_Tab_Perf_ToggleGameSettings"');
    perfRows.frameLimit = functionIncludes('"#QuickAccess_Tab_Perf_LimitFrameRate"');
    perfRows.reset = functionIncludes('"#QuickAccess_Tab_Perf_ResetToDefault"');
    const missing = Object.keys(perfRows).filter((k) => !perfRows[k]);
    if (missing.length) log('Steam\'s Performance rows not found: ' + missing.join(', '));
    return perfRows.overlayLevel && perfRows.perGame && perfRows.frameLimit;
  }

  // An error in a panel shows what failed (or what was there before), not a broken menu.
  let ErrorBoundary = null;
  function makeErrorBoundary() {
    ErrorBoundary = class extends React.Component {
      constructor(props) { super(props); this.state = { error: null }; }
      static getDerivedStateFromError(error) { return { error }; }
      componentDidCatch(error, info) { report((this.props.what || 'a panel') + ' failed', (error && error.stack || error) + '\n' + (info && info.componentStack || '')); }
      render() {
        if (!this.state.error) return this.props.children || null;
        if (this.props.fallback !== undefined) return this.props.fallback;
        return h('div', { style: { padding: '8px 16px', color: '#ff8080', fontSize: '13px', whiteSpace: 'pre-wrap', userSelect: 'text' } },
                 (this.props.what || 'This') + ' failed: ' + String(this.state.error && this.state.error.message || this.state.error));
      }
    };
  }

  // A value the app keeps (performance state, display settings) as React state.
  function useWatch(subscribe, read) {
    const [, bump] = React.useReducer((x) => x + 1, 0);
    React.useEffect(() => subscribe(bump), []);
    return read();
  }
  const watchPerf = (fn) => { perf.watchers.add(fn); askState(); return () => perf.watchers.delete(fn); };

  // --- Icons (24x24, drawn in the tab's color) ---
  const icon = (paths, size) => h('svg', { xmlns: 'http://www.w3.org/2000/svg', viewBox: '0 0 24 24', width: size || '1em', height: size || '1em', fill: 'currentColor' },
                                  paths.map((d, i) => h('path', { key: i, d })));
  const PlugIcon = () => icon(['M8 2h2v5H8zM14 2h2v5h-2z', 'M5 8h14v3.5a7 7 0 0 1-6 6.93V22h-2v-3.57a7 7 0 0 1-6-6.93z']);
  const BackIcon = () => icon(['M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20z']);
  const SunIcon = () => icon(['M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10z', 'M11 1h2v3h-2zM11 20h2v3h-2zM1 11h3v2H1zM20 11h3v2h-3zM4.22 5.64l1.42-1.42 2.12 2.12-1.42 1.42zM16.24 17.66l1.42-1.42 2.12 2.12-1.42 1.42zM4.22 18.36l2.12-2.12 1.42 1.42-2.12 2.12zM16.24 6.34l2.12-2.12 1.42 1.42-2.12 2.12z']);
  const LogsIcon = () => icon(['M6 2h9l5 5v15H6zM14 3.5V8h4.5z', 'M8.5 11h9v1.6h-9zM8.5 14.5h9v1.6h-9zM8.5 18h6v1.6h-6z']);
  const PuzzleIcon = () => icon(['M20.5 11H19V7a2 2 0 0 0-2-2h-4V3.5a2.5 2.5 0 0 0-5 0V5H4a2 2 0 0 0-2 2v3.8h1.5a2.7 2.7 0 0 1 0 5.4H2V20a2 2 0 0 0 2 2h3.8v-1.5a2.7 2.7 0 0 1 5.4 0V22H17a2 2 0 0 0 2-2v-4h1.5a2.5 2.5 0 0 0 0-5z']);

  // --- The Performance tab ---
  const RESOLUTIONS = [{ value: 0.5, label: '50%' }, { value: 0.75, label: '75%' }, { value: 1, label: 'Native' }];
  function ResolutionRow() {
    const app = useWatch(watchPerf, () => perf.app || {});
    const scale = typeof app.render_scale === 'number' ? app.render_scale : 1;
    let index = 0;
    RESOLUTIONS.forEach((r, i) => { if (Math.abs(r.value - scale) < Math.abs(RESOLUTIONS[index].value - scale)) index = i; });
    const later = app.game_running && Math.abs((app.launch_render_scale || 1) - scale) > 0.01;
    const description = later ? 'Takes effect the next time the game starts.'
      : 'Share of the screen’s pixels the game draws. Lower runs faster and cooler; Native is sharpest.';
    return h(ui.SliderField, {
      label: 'Resolution', description, value: index, min: 0, max: RESOLUTIONS.length - 1, step: 1,
      notchCount: RESOLUTIONS.length, notchLabels: RESOLUTIONS.map((r, i) => ({ notchIndex: i, label: r.label, value: i })),
      notchTicksVisible: false, layout: 'below', bottomSeparator: 'standard',
      onChange: (i) => { const r = RESOLUTIONS[i]; if (r) call('perf-app-setting', { key: 'render_scale', value: r.value }).then(takeState); },
    });
  }
  // A game started at 60 Hz goes faster only from its next start (it was told the screen's rate
  // as it started: GameProfiles.m); slower limits work at once.
  function FrameRateNote() {
    const app = useWatch(watchPerf, () => perf.app || {});
    if (!app.frame_rate_next_start) return null;
    return h('div', { style: { fontSize: '12px', lineHeight: '16px', opacity: 0.7, padding: '0 0 10px' } },
             'Above 60 fps takes effect the next time the game starts.');
  }

  function PerformancePanel() {
    const { PanelSection, PanelSectionRow } = ui;
    // Each of Steam's rows on its own: one that fails is left out, not the whole tab.
    const own = (component, props) => h(ErrorBoundary, { what: 'A Performance row', fallback: null }, h(component, props || {}));
    const row = (component, props, key) => component ? h(PanelSectionRow, { key }, own(component, props)) : null;
    return h(React.Fragment, null,
      h(PanelSection, null,
        perfRows.battery ? h(React.Fragment, { key: 'battery' }, own(perfRows.battery)) : null,
        row(perfRows.overlayLevel, null, 'overlay')),
      h(PanelSection, null,
        row(perfRows.header, null, 'header'),
        row(perfRows.perGame, null, 'per-game'),
        row(perfRows.frameLimit, null, 'frame-limit'),
        h(PanelSectionRow, { key: 'frame-rate-note' }, h(ErrorBoundary, { what: 'The frame rate note', fallback: null }, h(FrameRateNote))),
        ui.SliderField ? h(PanelSectionRow, { key: 'resolution' }, h(ErrorBoundary, { what: 'The resolution setting' }, h(ResolutionRow))) : null,
        row(perfRows.reset, { bottomSeparator: 'none' }, 'reset')));
  }

  // --- Plugins ---
  // Built-in plugins first, then the user's (Documents/plugins/<folder>: plugin.json, and the
  // script it names, run with (plugin, React, ui, AKPlugins) and returning or defining
  // { name, icon, content | Content, onDismount }).
  const plugins = { builtin: [], user: [], folder: '', listeners: new Set() };
  const pluginsChanged = () => { for (const fn of Array.from(plugins.listeners)) fn(); };
  const watchPlugins = (fn) => { plugins.listeners.add(fn); return () => plugins.listeners.delete(fn); };

  function displayPlugin() {
    const display = { brightness: 0.5, keepAwake: 'playing', loaded: false, listeners: new Set() };
    const changed = () => { for (const fn of Array.from(display.listeners)) fn(); };
    const take = (v) => { if (v) { Object.assign(display, v); display.loaded = true; changed(); } };
    const watch = (fn) => { display.listeners.add(fn); call('display').then(take); return () => display.listeners.delete(fn); };
    const KEEP_AWAKE = [
      { data: 'playing', label: 'While playing' },
      { data: 'always', label: 'Always' },
      { data: 'off', label: 'Never' },
    ];
    function Display() {
      const d = useWatch(watch, () => display);
      const { PanelSection, PanelSectionRow } = ui;
      return h(PanelSection, null,
        h(PanelSectionRow, null, h(ui.SliderField, {
          label: 'Brightness', value: Math.round(d.brightness * 100), min: 0, max: 100, step: 1, showValue: true, valueSuffix: '%',
          disabled: !d.loaded, layout: 'below',
          onChange: (v) => { display.brightness = v / 100; changed(); call('display-set', { brightness: v / 100 }); },
        })),
        ui.DropdownItem ? h(PanelSectionRow, null, h(ui.DropdownItem, {
          label: 'Keep the screen on', childrenContainerWidth: 'min', description: 'Stops the phone from locking itself while a controller is in use.',
          rgOptions: KEEP_AWAKE, selectedOption: d.keepAwake, disabled: !d.loaded, bottomSeparator: 'none',
          onChange: (o) => { display.keepAwake = o.data; changed(); call('display-set', { keepAwake: o.data }).then(take); },
        })) : null);
    }
    return { id: 'builtin:display', name: 'Display', icon: h(SunIcon), Content: Display, builtin: true };
  }

  function logsPlugin() {
    function Logs() {
      const [status, setStatus] = React.useState('');
      const { PanelSection, PanelSectionRow } = ui;
      const share = () => {
        setStatus('Collecting logs…');
        call('share-logs').then((r) => setStatus(r && r.ok ? 'Shared ' + r.files + ' files (' + r.size + ').' : 'Couldn’t share: ' + ((r && r.error) || 'unknown error')));
      };
      return h(PanelSection, null,
        h(PanelSectionRow, null, h(ui.ButtonItem, {
          layout: 'below', onClick: share, bottomSeparator: 'none',
          description: 'Every log of the app and of Steam, zipped, to AirDrop, Files or any app (the share sheet is touch only).',
        }, 'Share logs')),
        status ? h(PanelSectionRow, null, h('div', { style: { padding: '6px 0', fontSize: '13px', opacity: 0.8 } }, status)) : null);
    }
    return { id: 'builtin:logs', name: 'Logs', icon: h(LogsIcon), Content: Logs, builtin: true };
  }

  const pluginAPI = () => ({
    React, ui,
    webpack: { findModule, findModuleExport, findModuleByExport, findModuleDetailsByExport },
    patcher: { afterPatch, beforePatch, replacePatch, callOriginal },
    react: { findInTree, findInReactTree, getReactRoot, createReactTreePatcher },
    icons: { PlugIcon, PuzzleIcon },
  });

  function loadUserPlugin(entry) {
    const plugin = { id: entry.id, name: entry.name || entry.id, version: entry.version || '', author: entry.author || '',
                     description: entry.description || '', enabled: entry.enabled !== false, error: entry.error || null };
    if (!plugin.enabled || plugin.error || typeof entry.source !== 'string') return plugin;
    let defined = null;
    const api = {
      id: plugin.id,
      name: plugin.name,
      define(definition) { defined = definition; },
      log: (...parts) => log('[plugin ' + plugin.id + '] ' + parts.map(describe).join(' ')),
      storage: {
        get: (key) => call('plugin-storage', { id: plugin.id, key: String(key) }),
        set: (key, value) => call('plugin-storage', { id: plugin.id, key: String(key), value: value === undefined ? null : value, set: true }),
      },
    };
    try {
      const factory = new win.Function('plugin', 'React', 'ui', 'AKPlugins', '"use strict";\n' + entry.source +
                                       '\n//# sourceURL=akplugin://' + encodeURIComponent(plugin.id) + '/' + (entry.main || 'index.js'));
      let result = factory(api, React, ui, pluginAPI());
      if (result === undefined) result = defined;
      if (typeof result === 'function' && !(result.prototype && result.prototype.render)) result = result();
      if (!result || typeof result !== 'object') throw new Error('it defined nothing (return an object, or call plugin.define)');
      if (result.name) plugin.name = String(result.name);
      plugin.icon = result.icon || h(PuzzleIcon);
      plugin.content = result.content;
      plugin.Content = result.Content;
      plugin.onDismount = result.onDismount;
      if (!plugin.content && !plugin.Content) throw new Error('it has no content (content: an element, or Content: a component)');
      log('plugin ' + plugin.id + ' loaded');
    } catch (e) {
      plugin.error = String(e && e.message || e);
      report('plugin ' + plugin.id + ' failed to load', e);
    }
    return plugin;
  }

  function reloadUserPlugins() {
    return call('plugins').then((answer) => {
      for (const p of plugins.user) { if (typeof p.onDismount === 'function') { try { p.onDismount(); } catch (e) { report('plugin ' + p.id + ' onDismount', e); } } }
      plugins.folder = answer && answer.folder || '';
      plugins.user = (answer && Array.isArray(answer.plugins) ? answer.plugins : []).map(loadUserPlugin);
      pluginsChanged();
    });
  }

  function TitleRow(props) {
    const style = { display: 'flex', alignItems: 'center', paddingRight: '16px', position: 'sticky', top: '0px' };
    const className = ui.qamClasses.Title;
    if (!props.back) return h('div', { className, style }, h('div', { style: { marginRight: 'auto', flex: 0.9 } }, props.title));
    return h(ui.Focusable || 'div', { className, style },
      h(ui.DialogButton || 'button', { style: { height: '28px', width: '40px', minWidth: 0, padding: '10px 12px', marginRight: '12px' }, onClick: props.back },
        h('div', { style: { marginTop: '-4px', display: 'block' } }, h(BackIcon))),
      h('div', { style: { flex: 0.9, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } }, props.title));
  }

  function PluginRow(props) {
    const p = props.plugin;
    return h(ui.PanelSectionRow, null, h(ui.ButtonItem, { layout: 'below', onClick: props.open, disabled: !!p.error || !p.enabled },
      h('div', { style: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '12px' } },
        h('div', { style: { display: 'flex', fontSize: '20px' } }, p.icon || h(PuzzleIcon)),
        h('div', { style: { flex: 1, textAlign: 'left', overflow: 'hidden', textOverflow: 'ellipsis' } }, p.name),
        p.error ? h('div', { style: { fontSize: '12px', color: '#ff8080' } }, 'failed') : !p.enabled ? h('div', { style: { fontSize: '12px', opacity: 0.6 } }, 'off') : null)));
  }

  function PluginsPanel() {
    useWatch(watchPlugins, () => null);
    const [activeId, setActive] = React.useState(null);
    const [manage, setManage] = React.useState(false);
    const all = plugins.builtin.concat(plugins.user);
    const active = activeId && all.find((p) => p.id === activeId);
    const { PanelSection, PanelSectionRow } = ui;
    const back = () => { setActive(null); setManage(false); };
    const onCancelButton = (e) => { back(); if (e && e.stopPropagation) e.stopPropagation(); };
    if (active) {
      return h(ui.Focusable || 'div', { onCancelButton },
        h(TitleRow, { title: active.name, back }),
        h('div', { style: { paddingTop: '16px' } },
          h(ErrorBoundary, { what: active.name, key: active.id }, active.Content ? h(active.Content) : active.content)));
    }
    if (manage) {
      return h(ui.Focusable || 'div', { onCancelButton },
        h(TitleRow, { title: 'Your plugins', back }),
        h('div', { style: { paddingTop: '16px' } },
          h(PanelSection, null,
            plugins.user.length === 0 ? h(PanelSectionRow, null, h(ui.Field || 'div', {
              label: 'No plugins yet', bottomSeparator: 'none',
              description: 'Put a plugin’s folder in ' + (plugins.folder || 'Documents/plugins') + ' (the Files app shows it under this app). README.txt there explains how to write one.',
            })) : null,
            plugins.user.map((p) => h(PanelSectionRow, { key: p.id }, h(ui.ToggleField, {
              label: p.name + (p.version ? ' ' + p.version : ''),
              description: p.error ? 'Failed: ' + p.error : [p.author && 'by ' + p.author, p.description].filter(Boolean).join(' — ') || undefined,
              checked: p.enabled,
              onChange: (enabled) => call('plugin-enable', { id: p.id, enabled: !!enabled }).then(reloadUserPlugins),
            }))),
            h(PanelSectionRow, null, h(ui.ButtonItem, { layout: 'below', bottomSeparator: 'none', onClick: () => { reloadUserPlugins(); } }, 'Reload plugins')))));
    }
    return h(React.Fragment, null,
      h(TitleRow, { title: 'Plugins' }),
      h('div', { style: { paddingTop: '16px' } },
        h(PanelSection, null, all.filter((p) => p.builtin || p.enabled || p.error).map((p) => h(PluginRow, { key: p.id, plugin: p, open: () => setActive(p.id) }))),
        h(PanelSection, { title: 'Your plugins' },
          h(PanelSectionRow, null, h(ui.ButtonItem, {
            layout: 'below', bottomSeparator: 'none', onClick: () => setManage(true),
            description: plugins.user.length ? plugins.user.length + ' installed' : 'Add your own from the Files app',
          }, 'Manage plugins')))));
  }

  // --- The Quick Access menu (decky-loader's TabsHook) ---
  const PERF_TAB = 5;          // Steam's QuickAccessTab.Perf
  const PLUGINS_TAB = 1999;    // a key of our own
  let perfIcon = null;
  function addTabs(tabs) {
    if (!Array.isArray(tabs)) return;
    const perfTab = tabs.find((t) => t && t.key === PERF_TAB);
    if (perfTab && !perfTab.__akdeck && canShowPerformance()) {
      perfTab.__akdeck = true;
      const original = perfTab.panel;
      perfTab.panel = h(ErrorBoundary, { what: 'The Performance tab', fallback: original }, h(PerformancePanel));
    } else if (!perfTab && canShowPerformance() && perfIcon && !tabs.some((t) => t && t.__akdeckPerf)) {
      tabs.splice(Math.min(tabs.length, 4), 0, {
        key: PERF_TAB, __akdeck: true, __akdeckPerf: true, tab: h(perfIcon), strTitle: 'Performance',
        title: h('div', { className: ui.qamClasses.Title }, 'Performance'),
        panel: h(ErrorBoundary, { what: 'The Performance tab' }, h(PerformancePanel)),
      });
    }
    if (canShowPlugins() && !tabs.some((t) => t && t.key === PLUGINS_TAB)) {
      tabs.push({
        key: PLUGINS_TAB, title: null, tab: h(PlugIcon), strTitle: 'Plugins', __akdeck: true,
        panel: h(ErrorBoundary, { what: 'Plugins' }, h(PluginsPanel)),
      });
    }
  }

  let perfRowsFound = false;
  function hookQuickAccess() {
    const isMenu = (name) => (e) => e && e.type && source(e.type).includes(name);
    const menuModule = findModuleByExport(isMenu('QuickAccessMenuBrowserView'));
    if (!menuModule) return false;
    const browserView = Object.values(menuModule).find(isMenu('QuickAccessMenuBrowserView'));
    const embedded = Object.values(menuModule).find(isMenu('QuickAccessMenuEmbedded'));
    const patcher = createReactTreePatcher(
      [(tree) => findInReactTree(tree, (node) => node && node.props && node.props.onFocusNavDeactivated)],
      (args, ret) => {
        try {
          const tabs = findInReactTree(ret, (x) => x && x.props && x.props.tabs);
          if (tabs) addTabs(tabs.props.tabs);
        } catch (e) {
          report('adding the Quick Access tabs', e);
        }
        return ret;
      });
    afterPatch(browserView, 'type', patcher);
    if (embedded) afterPatch(embedded, 'type', patcher);
    // A menu already on screen re-renders with the patched renderer.
    const root = getReactRoot(win.document.getElementById('root'));
    const node = root && findInReactTree(root, (n) => n.elementType === browserView || (embedded && n.elementType === embedded));
    if (node) {
      node.type = node.elementType.type;
      if (node.alternate) node.alternate.type = node.type;
    }
    log('Quick Access menu hooked' + (embedded ? ' (both kinds)' : '') + ': Performance tab ' +
        (canShowPerformance() ? 'in the Deck layout' : 'left as Steam has it') + ', Plugins tab ' +
        (canShowPlugins() ? 'added' : 'left out (Steam components missing)'));
    return true;
  }

  // --- Start, once Steam's interface has started (as Decky waits) ---
  const started = () => {
    const app = win.App;
    try {
      return !!(app && ((app.BFinishedInitBeforeLogin && app.BFinishedInitBeforeLogin()) ||
                        (app.BFinishedInitStageOne && app.BFinishedInitStageOne())));
    } catch (e) { return false; }
  };
  let tries = 0;
  function start() {
    if (!started() || !requireFn()) { win.setTimeout(start, 250); return; }
    try {
      if (!React && !findComponents()) {
        if (++tries <= 40) { win.setTimeout(start, 500); return; }
        log('Steam\'s React wasn\'t found: the Quick Access menu stays as Steam has it');
        return;
      }
      if (!ErrorBoundary) makeErrorBoundary();
      perfRowsFound = !!findPerfRows();
      perfIcon = perfIcon || findModuleExport((e, name) => name === 'QAMPerformance' && typeof e === 'function');
      if (!plugins.builtin.length) plugins.builtin = [displayPlugin(), logsPlugin()];
      if (!hookQuickAccess()) {
        if (++tries <= 120) { win.setTimeout(start, 1000); return; }
        log('the Quick Access menu wasn\'t found');
        return;
      }
      reloadUserPlugins();
      win.AKPlugins = Object.assign(pluginAPI(), { reload: reloadUserPlugins });
    } catch (e) {
      report('starting', e);
    }
  }
  win.setTimeout(start, 0);
}
