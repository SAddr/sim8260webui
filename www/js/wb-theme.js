/* =============================================================
   wb-theme.js — 双主题切换（深色 / 亮色）
   · localStorage key: wb-theme
   · 通过 <html data-theme="..."> 切换
   · 暴露 window.wbTheme.toggle() / set(name) / get()
   · 在每个页面侧边栏底部自动注入「🌙 / ☀️」按钮
   ============================================================= */
(function () {
  'use strict';

  /* =============================================================
     全局请求超时 + 可见提示（所有页面共用，改这一处即全站生效）

     · 原生 fetch 没有超时。后端 CGI 一旦卡住（AT 桥某条腿掉了 / 串口在排队），
       浏览器会一直转圈而且永远不会报错 —— 这就是「web 上 AT 全部转圈圈无响应」。
     · 这里包一层：超过 timeoutMs 自动 abort，并弹出一个可见提示条，
       把「无限转圈」变成「明确的超时提示 + 自检入口」。
     · 调用方可用 { timeoutMs: 60000 } 覆盖默认值；已自带 signal 的请求不动。
     · 提示做了 12s 节流，避免开启自动刷新时反复闪烁。
     ============================================================= */
  var FETCH_TIMEOUT_MS = 45000;
  var _nativeFetch = window.fetch ? window.fetch.bind(window) : null;
  var _lastBannerAt = 0;

  function showTimeoutBanner(msg) {
    try {
      var now = Date.now();
      if (now - _lastBannerAt < 12000) return;   // 节流
      _lastBannerAt = now;
      var el = document.getElementById('wb-timeout-banner');
      if (!el) {
        el = document.createElement('div');
        el.id = 'wb-timeout-banner';
        el.style.cssText = 'position:fixed;left:50%;top:12px;transform:translateX(-50%);' +
          'z-index:99999;max-width:92vw;padding:10px 16px;border-radius:8px;' +
          'background:#b3261e;color:#fff;font-size:13px;line-height:1.5;' +
          'box-shadow:0 6px 20px rgba(0,0,0,.35);display:none;';
        (document.body || document.documentElement).appendChild(el);
      }
      el.textContent = msg;
      el.style.display = 'block';
      if (el._wbTimer) clearTimeout(el._wbTimer);
      el._wbTimer = setTimeout(function () { el.style.display = 'none'; }, 8000);
    } catch (e) {}
  }

  if (_nativeFetch) {
    // ---- 单次请求（带超时）----
    function _doFetch(input, init) {
      init = init || {};
      var ms = init.timeoutMs || FETCH_TIMEOUT_MS;
      if (init.signal || typeof AbortController === 'undefined') return _nativeFetch(input, init);
      var ctl = new AbortController();
      var timer = setTimeout(function () { ctl.abort(); }, ms);
      init.signal = ctl.signal;
      return _nativeFetch(input, init).then(function (r) {
        clearTimeout(timer);
        return r;
      }, function (err) {
        clearTimeout(timer);
        if (err && err.name === 'AbortError') {
          var secs = Math.round(ms / 1000);
          showTimeoutBanner('请求超时（' + secs + 's 无响应）：串口桥可能异常。' +
            '可在模块上执行 bridge_status.sh 自检；也可先关掉「⟳ 自动刷新」减少请求排队。');
          throw new Error('请求超时（' + secs + 's 无响应）');
        }
        throw err;
      });
    }

    /* ---- AT 串口请求「客户端串行化」----
       模块侧 CGI 已用锁把 AT 命令串起来，但前端多路并发（例如进入网络页会同时
       loadWWAN / loadBand / loadCell / loadNetMode，loadBand 内再 Promise.all 两路）
       会让后到的请求全部堵在服务端排队；一旦某条卡住，后面的会一起等到超时。
       这里在客户端就把 /cgi-bin/atcmd 的请求排成一条链：前一个结束才开始下一个，
       超时也从「真正开始」计时（排队的等待不计入超时），使行为可预期。 */
    var _atChain = Promise.resolve();
    function _isAtRequest(input) {
      try {
        var u = (typeof input === 'string') ? input : ((input && input.url) || '');
        return u.indexOf('/cgi-bin/atcmd') !== -1;
      } catch (e) { return false; }
    }

    window.fetch = function (input, init) {
      if (_isAtRequest(input)) {
        var p = _atChain.then(
          function () { return _doFetch(input, init); },
          function () { return _doFetch(input, init); }
        );
        // 链本身吞掉异常，避免一次失败导致后续请求全部不再执行
        _atChain = p.then(function () {}, function () {});
        return p;
      }
      return _doFetch(input, init);
    };
  }

  // 若 URL 内嵌 basic-auth 凭据（如用户收藏了 http://admin:admin@192.168.225.1:8888/），
  // fetch 规范禁止构造带凭据的 URL，会导致全站 AJAX 全部失败。
  // 注意：Chromium 的 location.href 会隐藏凭据、location.username 可能为 undefined，
  // 但 document.baseURI 保留凭据——必须检测 baseURI 并真实跳转（replaceState 无效）。
  // 浏览器认证缓存已记住凭据，干净 URL 重新加载时自动带 Authorization 头，不弹密码框。
  try {
    var bm = document.baseURI.match(/^(https?:\/\/)([^/@]*@)?([^/]*)([\s\S]*)$/);
    if (bm && bm[2]) {
      location.replace(bm[1] + bm[3] + (bm[4] || '/'));
      return; // 页面即将跳转，停止执行
    }
  } catch (e) {}

  var KEY = 'wb-theme';
  var DARK = 'dark';
  var LIGHT = 'light';
  var DEFAULT = DARK;

  function get() {
    try { return localStorage.getItem(KEY) || DEFAULT; }
    catch (e) { return DEFAULT; }
  }
  function set(name) {
    try { localStorage.setItem(KEY, name); } catch (e) {}
    document.documentElement.setAttribute('data-theme', name);
    syncBtn();
  }
  function toggle() { set(get() === DARK ? LIGHT : DARK); }

  // 早于 body 渲染前应用，避免主题闪烁（FOUC）
  var saved = DEFAULT;
  try { saved = localStorage.getItem(KEY) || DEFAULT; } catch (e) {}
  document.documentElement.setAttribute('data-theme', saved);

  // 注入主题切换按钮到侧边栏底部
  function injectToggle() {
    var foot = document.querySelector('.topbar-foot')
            || (function () {
                // 找侧边栏最后那个 div
                var tb = document.querySelector('.topbar');
                if (!tb) return null;
                var d = document.createElement('div');
                d.className = 'topbar-foot';
                tb.appendChild(d);
                return d;
              })();
    if (!foot || foot.querySelector('.theme-toggle')) return;
    var btn = document.createElement('button');
    btn.className = 'theme-toggle';
    btn.type = 'button';
    btn.title = '切换深色/亮色主题';
    btn.setAttribute('aria-label', '切换主题');
    foot.appendChild(btn);
    btn.addEventListener('click', toggle);
    syncBtn();
  }
  function syncBtn() {
    var btn = document.querySelector('.theme-toggle');
    if (!btn) return;
    var cur = get();
    btn.innerHTML = cur === DARK ? '☀️' : '🌙';
  }

  // 暴露 API
  window.wbTheme = { get: get, set: set, toggle: toggle, LIGHT: LIGHT, DARK: DARK };

  /* =============================================================
     全局「自动刷新」开关（右上角，默认关闭）
     · 页面通过 window.__pageRefresh 注册自己的刷新函数
     · 点击开关 → 每 5s 调用 __pageRefresh()；再点关闭
     ============================================================= */
  var REFRESH_MS = 5000;
  var refreshTimer = null;

  function injectAutoRefresh() {
    if (document.getElementById('auto-refresh-btn')) return;
    var btn = document.createElement('button');
    btn.className = 'auto-refresh';
    btn.id = 'auto-refresh-btn';
    btn.type = 'button';
    btn.setAttribute('aria-label', '自动刷新开关');
    document.body.appendChild(btn);
    btn.addEventListener('click', toggleAutoRefresh);
    syncAutoRefresh();
  }
  function toggleAutoRefresh() {
    if (refreshTimer) { stopAutoRefresh(); } else { startAutoRefresh(); }
  }
  function startAutoRefresh() {
    if (refreshTimer) return;
    if (typeof window.__pageRefresh === 'function') {
      try { window.__pageRefresh(); } catch (e) {}
    }
    refreshTimer = setInterval(function () {
      if (typeof window.__pageRefresh === 'function') {
        try { window.__pageRefresh(); } catch (e) {}
      }
    }, REFRESH_MS);
    syncAutoRefresh();
  }
  function stopAutoRefresh() {
    if (refreshTimer) { clearInterval(refreshTimer); refreshTimer = null; }
    syncAutoRefresh();
  }
  function isRefreshing() { return !!refreshTimer; }
  function syncAutoRefresh() {
    var btn = document.getElementById('auto-refresh-btn');
    if (!btn) return;
    var on = !!refreshTimer;
    btn.classList.toggle('on', on);
    btn.innerHTML = on ? '⟳ 刷新中' : '⟳ 自动刷新';
    btn.title = on ? '点击关闭（当前每 5 秒刷新）' : '点击开启每 5 秒自动刷新（默认关闭）';
  }
  window.wbRefresh = { start: startAutoRefresh, stop: stopAutoRefresh, toggle: toggleAutoRefresh, isOn: isRefreshing };

  // 移动端横滑导航：让当前激活的 tab 自动滚动到可视区中央
  function scrollActiveTab() {
    var tab = document.querySelector('.nav-tab.active');
    if (!tab || !tab.scrollIntoView) return;
    try { tab.scrollIntoView({ inline: 'center', block: 'nearest' }); }
    catch (e) { tab.scrollIntoView(false); }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { injectToggle(); injectAutoRefresh(); scrollActiveTab(); });
  } else {
    injectToggle();
    injectAutoRefresh();
    scrollActiveTab();
  }
})();
