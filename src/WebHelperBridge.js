// The SteamClient object for the Safari-engine web helper. WebHelperWeb.m injects this into
// Steam's pages (it is compiled into WebHelperBridge.inc by tools/gen-bridge.js) and calls
// install(window, config) at document start; the window.open wrapper below also installs it
// into each popup Steam's UI opens.
//
// It rebuilds what Steam Helper's renderer does with V8 (webhelperv8.cpp, recovered from its
// arm64 code):
//  - Every method the client registers (CMsgJSRegisterMethod) becomes SteamClient.<dotted
//    name>. A call is sent to the client as CMsgJSMethodCall with the arguments converted to
//    CMsgJSValue: booleans; integers that fit int32 as int_value, then uint32 as uint_value,
//    other numbers as double_value; strings; arrays and objects (own enumerable keys)
//    recursively. A function argument at the top level becomes a function_handle the client
//    can call back (CMsgJSExecuteCallback); undefined, null and other values can't be sent
//    and the call throws "Could not encode argument N", as the original does.
//  - Function methods return nothing. Callback methods need a function as their last
//    argument and return { unregister() }. Promise methods append { resolve, reject }
//    function handles to the arguments and return a promise the client settles by calling
//    one of them.
//  - Values the client sends back: bool/int/uint/double/string as such, bytes as an
//    ArrayBuffer, arrays and objects recursively.
//  - The helper's own functions (Window.*, Browser.*, BrowserView.*, ...) are implemented
//    here and in WebHelperWeb.m; on a phone every window is the full screen.
// The page talks to the app through window.webkit.messageHandlers.steamclient; the app
// answers through window.__akwhDispatch. The few answers needed synchronously (the browser's
// own id) come through window.prompt, which WebHelperWeb.m answers at once.
function akwhInstall(win, config) {
  'use strict';
  if (win.__akwhDispatch) return;
  const handler = win.webkit && win.webkit.messageHandlers && win.webkit.messageHandlers.steamclient;
  if (!handler) return;
  const post = (msg) => handler.postMessage(msg);
  const syncCall = (op) => {
    const answer = win.prompt('akwh-sync:' + op, '');
    return answer == null ? undefined : JSON.parse(answer);
  };

  // Functions the client (or the app) can call back, by handle. Handles are per window; the
  // app tells windows apart.
  const functions = new Map();
  let nextHandle = 1;
  const addFunction = (fn) => { const h = nextHandle++; functions.set(h, fn); return h; };

  function encode(v) {
    switch (typeof v) {
      case 'boolean': return { bool_value: v };
      case 'number':
        if (Number.isInteger(v) && !Object.is(v, -0)) {
          if (v >= -2147483648 && v <= 2147483647) return { int_value: v };
          if (v >= 0 && v <= 4294967295) return { uint_value: v };
        }
        return { double_value: v };
      case 'string': return { string_value: v };
      case 'function': return { is_object: true, object_properties: [] };
      case 'object': {
        if (v === null) return null;
        if (Array.isArray(v)) {
          const values = [];
          for (let i = 0; i < v.length; i++) {
            const e = encode(v[i]);
            if (!e) return null;
            values.push(e);
          }
          return { is_array: true, array_values: values };
        }
        const props = [];
        for (const key of Object.keys(v)) {
          const e = encode(v[key]);
          if (!e) return null;
          props.push({ name: key, value: e });
        }
        return { is_object: true, object_properties: props };
      }
      default: return null;
    }
  }

  function encodeArgs(args) {
    const out = [];
    for (let i = 0; i < args.length; i++) {
      const a = args[i];
      if (typeof a === 'function') { out.push({ function_handle: addFunction(a) }); continue; }
      const e = encode(a);
      if (!e) throw new Error('Could not encode argument ' + i);
      out.push(e);
    }
    return out;
  }

  function base64ToBuffer(s) {
    const bin = win.atob(s);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes.buffer;
  }

  function decode(v) {
    if (!v || typeof v !== 'object') return undefined;
    if ('bool_value' in v) return !!v.bool_value;
    if ('int_value' in v) return v.int_value;
    if ('uint_value' in v) return v.uint_value;
    if ('double_value' in v) return v.double_value;
    if ('string_value' in v) return v.string_value;
    if ('bytes_value' in v) return base64ToBuffer(v.bytes_value);
    if (v.is_array) return (v.array_values || []).map(decode);
    if (v.is_object) {
      const o = {};
      for (const p of v.object_properties || []) o[p.name] = decode(p.value);
      return o;
    }
    return undefined;
  }

  const SteamClient = (win.SteamClient && typeof win.SteamClient === 'object') ? win.SteamClient : {};
  Object.defineProperty(SteamClient, '__akwh', { value: true });
  win.SteamClient = SteamClient;

  function namespace(path) {
    let o = SteamClient;
    for (const part of path) {
      if (o[part] == null) o[part] = {};
      o = o[part];
    }
    return o;
  }

  function define(dotted, fn) {
    const parts = dotted.split('.');
    const leaf = parts.pop();
    const ns = namespace(parts);
    if (!(leaf in ns)) ns[leaf] = fn;
  }

  // Methods the client registered.
  function addMethod(name, type) {
    let fn;
    if (type === 2) {
      fn = function () {
        const args = Array.from(arguments);
        if (!args.length || typeof args[args.length - 1] !== 'function')
          throw new Error('Client methods registered as callbacks require the last param to be a function');
        const encoded = encodeArgs(args);
        const handle = encoded[encoded.length - 1].function_handle;
        post({ op: 'call', name, args: encoded });
        return {
          unregister() {
            if (!functions.delete(handle)) return;
            post({ op: 'release', handle });
          },
        };
      };
    } else if (type === 3) {
      fn = function () {
        const encoded = encodeArgs(Array.from(arguments));
        return new win.Promise((resolve, reject) => {
          let hResolve, hReject;
          const settle = (f) => (value) => { functions.delete(hResolve); functions.delete(hReject); f(value); };
          hResolve = addFunction(settle(resolve));
          hReject = addFunction(settle(reject));
          encoded.push({ is_object: true, object_properties: [
            { name: 'resolve', value: { function_handle: hResolve } },
            { name: 'reject', value: { function_handle: hReject } },
          ] });
          post({ op: 'call', name, args: encoded });
        });
      };
    } else {
      fn = function () { post({ op: 'call', name, args: encodeArgs(Array.from(arguments)) }); };
    }
    define(name, fn);
  }

  // Calls into the app that answer later.
  const replies = new Map();
  let nextReply = 1;
  const ask = (op, name, args) => new win.Promise((resolve) => {
    const id = nextReply++;
    replies.set(id, resolve);
    post({ op, name, args, reply: id });
  });
  const tell = (op, name, args) => post({ op, name, args });

  // This window's ids: the small one Browser.GetBrowserID returns (CEF's identifier, used
  // in popup names and URLs) and Steam's handle.
  let ids;
  const browserIds = () => ids || (ids = syncCall('browser-id') || { id: 0, handle: 0 });

  // --- The helper's own functions ---
  const resolved = (v) => win.Promise.resolve(v);
  const windowOp = (name) => function () { tell('window', name, Array.from(arguments)); };
  const windowAsk = (name) => function () { return ask('window', name, Array.from(arguments)); };
  const noop = function () {};
  const registration = (store) => function (callback) {
    if (typeof callback === 'function') store.add(callback);
    return { unregister() { store.delete(callback); } };
  };

  const screenCss = () => config.screen || { width: win.innerWidth, height: win.innerHeight };
  const builtins = {
    'Window.BringToFront': windowOp('BringToFront'),
    'Window.Close': windowOp('Close'),
    'Window.DefaultMonitorHasFullscreenWindow': () => resolved(true),
    'Window.GetDefaultMonitorDimensions': () => {
      const s = screenCss();
      return resolved({ nUsableLeft: 0, nUsableTop: 0, nUsableWidth: s.width, nUsableHeight: s.height,
                        nFullLeft: 0, nFullTop: 0, nFullWidth: s.width, nFullHeight: s.height,
                        flHorizontalScale: 1, flVerticalScale: 1 });
    },
    'Window.GetMousePositionDetails': () => resolved(undefined),
    'Window.GetWindowDetails': () => resolved({ bMaximized: true, bMinimized: false, bHidden: false }),
    'Window.GetWindowDimensions': () => resolved({ x: 0, y: 0, width: win.innerWidth, height: win.innerHeight }),
    'Window.GetWindowRestoreDetails': () => resolved(''),
    'Window.HideWindow': windowOp('HideWindow'),
    'Window.IsWindowMaximized': () => resolved(true),
    'Window.IsWindowMinimized': () => resolved(false),
    'Window.MarkLastFocused': noop,
    'Window.Minimize': windowOp('Minimize'),
    'Window.MoveTo': noop,
    'Window.MoveToLocation': noop,
    'Window.PositionWindowRelative': noop,
    'Window.ProcessShuttingDown': noop,
    'Window.ResizeTo': noop,
    'Window.RestoreWindowSizeAndPosition': noop,
    'Window.SetComposition': noop,
    'Window.SetHideOnClose': noop,
    'Window.SetKeyFocus': windowOp('SetKeyFocus'),
    'Window.SetMaxSize': noop,
    'Window.SetMinSize': noop,
    'Window.SetModal': noop,
    'Window.SetResizeGrip': noop,
    'Window.SetWindowFlashing': noop,
    'Window.SetWindowIcon': noop,
    'Window.ShowWindow': windowOp('ShowWindow'),
    'Window.ToggleFullScreen': noop,
    'Window.ToggleMaximize': noop,

    'Browser.AddWordToDictionary': noop,
    'Browser.ClearAllBrowsingData': () => tell('browser', 'ClearAllBrowsingData', []),
    'Browser.ClearHistory': noop,
    'Browser.CloseDevTools': noop,
    'Browser.GetBrowserID': () => browserIds().id,
    'Browser.GetSpellingSuggestions': () => resolved([]),
    'Browser.GetSteamBrowserID': () => browserIds().handle,
    'Browser.HideCursorUntilMouseEvent': noop,
    'Browser.InspectElement': noop,
    'Browser.NotifyUserActivation': noop,
    'Browser.OpenDevTools': noop,
    'Browser.Paste': noop,
    'Browser.RemoveAllBackstackEntries': noop,
    'Browser.ReplaceMisspelling': noop,
    'Browser.RestartJSContext': () => tell('browser', 'RestartJSContext', []),
    'Browser.SetBackgroundThrottlingDisabled': noop,
    'Browser.SetPendingFilePath': noop,
    'Browser.SetTouchGesturesToCancel': noop,
    'Browser.StartDownload': (url) => tell('browser', 'StartDownload', [String(url)]),

    'Input.EnableControllerAnalogInputMessages': noop,
    'Input.RegisterForControllerAnalogInputMessages': registration(new Set()),
    'Input.RegisterForControllerInputMessages': registration(new Set()),
    'Input.RegisterForKeyboardDeviceChanges': registration(new Set()),
    'Input.RegisterForTouchMenuInputMessages': registration(new Set()),
    'Input.RegisterForTouchMenuMessages': registration(new Set()),
    'Input.RegisterForUIVisualization': registration(new Set()),

    'OpenVR.SetOverlayInteractionAffordance': noop,
    'OpenVR.TriggerOverlayHapticEffect': noop,
    'Compat.CheckBootProtectionEnabled': () => resolved(false),
    'System.ExitFakeCaptivePortal': noop,

    '_internal.BInGpuFallbackMode': () => false,
    '_internal.GetBrowserProcessDetails': () => resolved({}),
    '_internal.GetDisplayScaleFactors': () => resolved({ flSystem: 1, flDefault: 1 }),
    '_internal.IsDebuggingEnabled': () => false,
    '_internal.RequestDisableGpu': noop,
    '_internal.SetDevMode': noop,
    '_internal.SetForceDeviceScaleFactor': noop,
    '_internal.SetRightToLeftMode': noop,
  };

  // BrowserView: a second page shown inside a window (the Big Picture menus, store pages).
  // CreatePopup's views are filled by this window's own script through window.open; Create's
  // load a URL of their own.
  const views = new Map();
  let nextView = 1;
  class BrowserView {
    constructor(id) { this.id = id; this.listeners = new Map(); this.bounds = { x: 0, y: 0, width: 0, height: 0 }; }
    on(event, fn) {
      if (!this.listeners.has(event)) this.listeners.set(event, new Set());
      this.listeners.get(event).add(fn);
    }
    off(event, fn) { const set = this.listeners.get(event); if (set) set.delete(fn); }
    emit(event, args) {
      const set = this.listeners.get(event);
      if (!set) return undefined;
      let result;
      for (const fn of Array.from(set)) {
        try { const r = fn.apply(null, args); if (r !== undefined) result = r; } catch (e) { reportError(e); }
      }
      return result;
    }
    send(method, args) { post({ op: 'bv', id: this.id, name: method, args: Array.from(args) }); }
    LoadURL(url) { this.send('LoadURL', [String(url)]); }
    ReplaceURL(url) { this.send('LoadURL', [String(url)]); }
    Reload() { this.send('Reload', []); }
    GoBack() { this.send('GoBack', []); }
    GoForward() { this.send('GoForward', []); }
    SetVisible(visible) { this.send('SetVisible', [!!visible]); }
    SetBounds(x, y, width, height) {
      this.bounds = { x: +x || 0, y: +y || 0, width: +width || 0, height: +height || 0 };
      this.send('SetBounds', [this.bounds.x, this.bounds.y, this.bounds.width, this.bounds.height]);
    }
    GetBounds() { return Object.assign({}, this.bounds); }
    SetFocus(focus) { this.send('SetFocus', [focus !== false]); }
    AddGlass() {}
    PostMessage(message, args) { this.send('PostMessage', [String(message), args === undefined ? '' : String(args)]); }
    EnableSteamInput() {}
    NotifyUserActivation() {}
    SetTouchGesturesToCancel() {}
    SetBlockInput() {}
    HandleContextMenuCommand() {}
    SetSteamURLCallback() {}
    SetShowContextMenuCallback() {}
    SetBlockedProtocols() {}
    CanGoBackward() { return !!this.canGoBack; }
    CanGoForward() { return !!this.canGoForward; }
    Paste() {}
    FindInPage(text) { this.send('FindInPage', [String(text)]); }
    StopFindInPage() {}
    DialogResponse() {}
    SetVRKeyboardVisibility() {}
    AddHeader(key, value) { this.send('AddHeader', [String(key), String(value)]); }
  }
  builtins['BrowserView.Create'] = (options) => {
    const view = new BrowserView(nextView++);
    views.set(view.id, view);
    post({ op: 'bv-create', id: view.id, options: JSON.parse(JSON.stringify(options || {})) });
    return view;
  };
  builtins['BrowserView.CreatePopup'] = (options) => {
    const view = new BrowserView(nextView++);
    views.set(view.id, view);
    const opts = JSON.parse(JSON.stringify(options || {}));
    post({ op: 'bv-createpopup', id: view.id, options: opts });
    const parent = opts.parentPopupBrowserID != null ? opts.parentPopupBrowserID : 0;
    return { strCreateURL: 'about:blank?browserviewpopup=1&requestid=' + view.id + '&parentpopup=' + parent, browserView: view };
  };
  builtins['BrowserView.Destroy'] = (view) => {
    if (!view || !views.has(view.id)) return;
    views.delete(view.id);
    post({ op: 'bv-destroy', id: view.id });
  };
  const parentMessageListeners = new Set();
  builtins['BrowserView.RegisterForMessageFromParent'] = registration(parentMessageListeners);
  builtins['BrowserView.PostMessageToParent'] = (message, args) =>
    tell('browser', 'PostMessageToParent', [String(message), args === undefined ? '' : String(args)]);

  // WebSockets to Steam's own servers on this device (the UI's transport,
  // ws://localhost:<port>/transportsocket/). WebKit won't open a plain ws:// socket from an
  // https page (mixed content), and the page has to stay https://steamloopback.host - the
  // only origin Steam accepts there. So the app opens those sockets itself, with that Origin,
  // and relays the messages; other WebSockets stay WebKit's.
  const RealWebSocket = win.WebSocket;
  const sockets = new Map();
  let nextSocket = 1;
  const isLoopbackSocket = (url) => {
    try {
      const u = new win.URL(String(url), win.location.href);
      return u.protocol === 'ws:' && ['localhost', '127.0.0.1', '[::1]'].includes(u.hostname);
    } catch (e) { return false; }
  };
  const bytesToBase64 = (bytes) => {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return win.btoa(s);
  };
  class TunneledWebSocket extends win.EventTarget {
    constructor(url, protocols) {
      super();
      this.url = String(url);
      this.readyState = 0;
      this.binaryType = 'blob';
      this.bufferedAmount = 0;
      this.protocol = '';
      this.extensions = '';
      this.onopen = this.onmessage = this.onerror = this.onclose = null;
      this.id = nextSocket++;
      sockets.set(this.id, this);
      const list = protocols == null ? [] : [].concat(protocols).map(String);
      post({ op: 'ws-open', id: this.id, url: this.url, protocols: list });
    }
    send(data) {
      if (this.readyState === 0) throw new win.DOMException("Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.", 'InvalidStateError');
      if (this.readyState !== 1) return;
      if (typeof data === 'string') { post({ op: 'ws-send', id: this.id, text: data }); return; }
      const tag = Object.prototype.toString.call(data);
      if (tag === '[object Blob]') { data.arrayBuffer().then((buffer) => this.send(buffer)); return; }
      const bytes = tag === '[object ArrayBuffer]' ? new Uint8Array(data)
                  : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
      post({ op: 'ws-send', id: this.id, data: bytesToBase64(bytes) });
    }
    close(code, reason) {
      if (this.readyState >= 2) return;
      this.readyState = 2;
      post({ op: 'ws-close', id: this.id, code: code == null ? 1000 : code, reason: reason == null ? '' : String(reason) });
    }
    __fire(type, event) {
      const handler = this['on' + type];
      if (typeof handler === 'function') { try { handler.call(this, event); } catch (e) { reportError(e); } }
      this.dispatchEvent(event);
    }
    __deliver(m) {
      if (m.ev === 'open') {
        this.readyState = 1;
        this.protocol = m.protocol || '';
        this.__fire('open', new win.Event('open'));
      } else if (m.ev === 'message') {
        let data = m.text;
        if (!('text' in m)) data = this.binaryType === 'blob' ? new win.Blob([base64ToBuffer(m.data)]) : base64ToBuffer(m.data);
        this.__fire('message', new win.MessageEvent('message', { data }));
      } else if (m.ev === 'error') {
        this.__fire('error', new win.Event('error'));
      } else if (m.ev === 'close') {
        this.readyState = 3;
        sockets.delete(this.id);
        this.__fire('close', new win.CloseEvent('close', { code: m.code || 1006, reason: m.reason || '', wasClean: !!m.clean }));
      }
    }
  }
  const states = { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 };
  for (const [k, v] of Object.entries(states)) { TunneledWebSocket[k] = v; TunneledWebSocket.prototype[k] = v; }
  if (RealWebSocket) {
    const WebSocketShim = function WebSocket(url, protocols) {
      return isLoopbackSocket(url) ? new TunneledWebSocket(url, protocols)
                                   : (protocols === undefined ? new RealWebSocket(url) : new RealWebSocket(url, protocols));
    };
    for (const [k, v] of Object.entries(states)) WebSocketShim[k] = v;
    WebSocketShim.prototype = RealWebSocket.prototype;
    win.WebSocket = WebSocketShim;
  }

  // _internal.ExecutePromise only exists for the original's own promise trick.
  builtins['_internal.ExecutePromise'] = () => { throw new Error('SteamClient._internal.ExecutePromise(): Not expecting promise'); };

  for (const name of Object.keys(builtins)) define(name, builtins[name]);
  for (const [name, type] of config.methods || []) addMethod(name, type);

  function reportError(e) {
    try { post({ op: 'console', level: 'error', text: String(e && e.stack || e) }); } catch (ignored) {}
  }

  // Messages from the app.
  Object.defineProperty(win, '__akwhDispatch', {
    value(messages) {
      for (const m of messages) {
        try {
          if (m.t === 'call') {
            const fn = functions.get(m.h);
            if (fn) fn.apply(null, (m.a || []).map(decode));
          } else if (m.t === 'release') {
            functions.delete(m.h);
          } else if (m.t === 'reply') {
            const resolve = replies.get(m.id);
            replies.delete(m.id);
            if (resolve) resolve(m.v);
          } else if (m.t === 'bv') {
            const view = views.get(m.id);
            if (view) {
              if (m.ev === 'can-go-back-forward-changed') { view.canGoBack = !!m.a[0]; view.canGoForward = !!m.a[1]; }
              view.emit(m.ev, m.a || []);
            }
          } else if (m.t === 'ws') {
            const socket = sockets.get(m.id);
            if (socket) socket.__deliver(m);
          } else if (m.t === 'parent-message') {
            for (const fn of Array.from(parentMessageListeners)) fn.apply(null, m.a || []);
          } else if (m.t === 'methods') {
            for (const [name, type] of m.methods) addMethod(name, type);
            if (typeof win.SteamClientInitialized === 'function') win.SteamClientInitialized();
          } else if (m.t === 'exception') {
            win.console.error('SteamClient: ' + m.text);
          }
        } catch (e) {
          reportError(e);
        }
      }
    },
  });

  // Console output and uncaught errors go to the app's log.
  for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
    const original = win.console[level];
    win.console[level] = function () {
      try {
        const text = Array.from(arguments).map((a) => {
          if (typeof a === 'string') return a;
          if (a instanceof win.Error) return a.stack || String(a);
          try { return JSON.stringify(a); } catch (e) { return String(a); }
        }).join(' ');
        post({ op: 'console', level, text: text.length > 4000 ? text.slice(0, 4000) + '...' : text });
      } catch (e) {}
      return original.apply(win.console, arguments);
    };
  }
  win.addEventListener('error', (e) => reportError((e.error && e.error.stack) || (e.message + ' at ' + e.filename + ':' + e.lineno)));
  win.addEventListener('unhandledrejection', (e) => reportError('unhandled rejection: ' + ((e.reason && e.reason.stack) || e.reason)));

  // A phone-sized page: the width of the window, no zooming, no text inflation, no long-press
  // callouts. Steam writes its popups' documents itself (document.write), so this runs again
  // after that.
  function fitDocument(doc) {
    try {
      if (!doc || !doc.head) return;
      if (!doc.querySelector('meta[name=viewport]')) {
        const meta = doc.createElement('meta');
        meta.name = 'viewport';
        meta.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
        doc.head.insertBefore(meta, doc.head.firstChild);
      }
      // What takes focus (the first few times per document), for the log: a field that keeps
      // gaining and losing focus makes the keyboard come and go.
      const root = doc.documentElement;
      if (root && !root.__akwhFocusLog) {
        root.__akwhFocusLog = true;
        let count = 0;
        const describe = (el) => {
          if (!el || !el.tagName) return String(el);
          let s = el.tagName.toLowerCase();
          if (el.id) s += '#' + el.id;
          if (typeof el.className === 'string' && el.className.trim()) s += '.' + el.className.trim().split(/\s+/).slice(0, 3).join('.');
          if (el.type) s += '[type=' + el.type + ']';
          if (el.isContentEditable) s += '[contenteditable]';
          return s;
        };
        doc.addEventListener('focusin', (e) => {
          if (count++ < 60) post({ op: 'console', level: 'focus', text: 'focus -> ' + describe(e.target) });
        }, true);
      }
      if (!doc.getElementById('__akwh_style')) {
        const style = doc.createElement('style');
        style.id = '__akwh_style';
        style.textContent = 'html{-webkit-text-size-adjust:100%;-webkit-tap-highlight-color:transparent}' +
                            '*{-webkit-touch-callout:none}';
        doc.head.appendChild(style);
      }
    } catch (e) {}
  }
  if (win.document.readyState !== 'loading') fitDocument(win.document);
  win.document.addEventListener('DOMContentLoaded', () => fitDocument(win.document));

  // Popups: tell the app what is being opened (window.open's name doesn't reach it otherwise),
  // make sure the new window has SteamClient even if WebKit didn't inject this script into
  // its first document, and fit its document once Steam has written it.
  const realOpen = win.open;
  win.open = function (url, name, features) {
    post({ op: 'will-open', url: url == null ? '' : String(url), name: name == null ? '' : String(name),
           features: features == null ? '' : String(features) });
    const popup = realOpen.call(win, url, name, features);
    if (popup) {
      try { akwhInstall(popup, config); } catch (e) { reportError(e); }
      const fit = () => fitDocument(popup.document);
      win.queueMicrotask(fit);
      win.setTimeout(fit, 0);
      win.setTimeout(fit, 100);
    }
    return popup;
  };
}
