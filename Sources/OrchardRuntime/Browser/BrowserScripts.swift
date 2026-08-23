import Foundation

/// Every script the service injects into a page. Centralized so the security
/// posture is auditable in one place: scripts carry data *into* the page only as
/// JS string literals built by `literal(_:)` (never by splicing raw text), and
/// everything that comes back is a JSON string treated as untrusted data — page
/// content is never executed on the host as shell input or Swift-side eval.
public enum BrowserScripts {
    /// Encode a Swift string as a JS string literal. Escapes the characters that
    /// could break out of a literal (quote, backslash, newlines, U+2028/2029) so
    /// CLI-supplied text cannot inject script.
    static func literal(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Walk the live DOM into a flat pre-order node list and register interactive
    /// elements in `window.__orchardRefs = {epoch, els}` — the page-side half of
    /// the `@eN` ref table. Interactive elements are emitted without recursing
    /// (their accessible name already carries their text); structural roles keep
    /// nesting; leaf text becomes `text` nodes. Returns JSON:
    /// `{title, url, truncated, nodes:[{d, role, name, value, i}]}` where `i` is
    /// the element's index in `els` (-1 for non-interactive).
    static func snapshot(epoch: Int) -> String {
        """
        (function(){
          var MAX_NODES = 800, MAX_TEXT = 120;
          var els = [], nodes = [];
          function trim(s){ return (s||'').replace(/\\s+/g,' ').trim().slice(0, MAX_TEXT); }
          function role(el){
            var r = el.getAttribute && el.getAttribute('role');
            if (r) return r;
            var t = el.tagName ? el.tagName.toLowerCase() : '';
            if (t === 'a') return el.hasAttribute('href') ? 'link' : '';
            if (t === 'button') return 'button';
            if (t === 'select') return 'combobox';
            if (t === 'textarea') return 'textbox';
            if (t === 'img') return 'image';
            if (t === 'nav') return 'navigation';
            if (t === 'main') return 'main';
            if (t === 'header') return 'banner';
            if (t === 'footer') return 'contentinfo';
            if (t === 'form') return 'form';
            if (t === 'table') return 'table';
            if (t === 'ul' || t === 'ol') return 'list';
            if (t === 'li') return 'listitem';
            if (/^h[1-6]$/.test(t)) return 'heading';
            if (t === 'input') {
              var ty = (el.getAttribute('type')||'text').toLowerCase();
              if (ty === 'button' || ty === 'submit' || ty === 'reset') return 'button';
              if (ty === 'checkbox') return 'checkbox';
              if (ty === 'radio') return 'radio';
              if (ty === 'range') return 'slider';
              return 'textbox';
            }
            return '';
          }
          function isInteractive(el){
            var t = el.tagName ? el.tagName.toLowerCase() : '';
            if (t === 'a' && el.hasAttribute('href')) return true;
            if (t === 'button' || t === 'select' || t === 'textarea') return true;
            if (t === 'input' && (el.getAttribute('type')||'').toLowerCase() !== 'hidden') return true;
            if (el.isContentEditable) return true;
            if (el.hasAttribute('onclick')) return true;
            var r = el.getAttribute('role');
            if (r && /^(button|link|checkbox|radio|tab|menuitem|option|switch|combobox|textbox|searchbox|slider)$/.test(r)) return true;
            if (el.hasAttribute('tabindex') && parseInt(el.getAttribute('tabindex'),10) >= 0) return true;
            return false;
          }
          function name(el){
            var n = el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title') || el.getAttribute('placeholder');
            if (n) return trim(n);
            if (el.labels && el.labels.length) return trim(el.labels[0].textContent);
            var t = el.tagName.toLowerCase();
            if (t === 'input' || t === 'select') return trim(el.getAttribute('name') || '');
            return trim(el.innerText || el.textContent || '');
          }
          function value(el){
            var t = el.tagName.toLowerCase();
            if (t === 'input') {
              var ty = (el.getAttribute('type')||'text').toLowerCase();
              if (ty === 'password') return el.value ? '\\u2022\\u2022\\u2022' : '';
              if (ty === 'checkbox' || ty === 'radio') return el.checked ? 'checked' : '';
              return trim(el.value);
            }
            if (t === 'textarea' || t === 'select') return trim(el.value);
            return '';
          }
          function hidden(el){
            if (!window.getComputedStyle) return false;
            var s = window.getComputedStyle(el);
            return s.display === 'none' || s.visibility === 'hidden';
          }
          function walk(el, depth){
            if (nodes.length >= MAX_NODES || el.nodeType !== 1) return;
            var t = el.tagName.toLowerCase();
            if (t === 'script' || t === 'style' || t === 'noscript' || t === 'template') return;
            if (hidden(el)) return;
            var r = role(el);
            if (isInteractive(el)) {
              var idx = els.length; els.push(el);
              nodes.push({d: depth, role: r || 'generic', name: name(el), value: value(el), i: idx});
              return;
            }
            if (r === 'heading' || r === 'image') {
              nodes.push({d: depth, role: r, name: name(el), value: '', i: -1});
              return;
            }
            var childDepth = depth;
            if (r) {
              nodes.push({d: depth, role: r, name: trim(el.getAttribute('aria-label') || ''), value: '', i: -1});
              childDepth = depth + 1;
            }
            if (!el.firstElementChild) {
              var txt = trim(el.innerText || el.textContent);
              if (txt) nodes.push({d: childDepth, role: 'text', name: txt, value: '', i: -1});
              return;
            }
            for (var c = el.firstElementChild; c; c = c.nextElementSibling) walk(c, childDepth);
          }
          if (document.body) walk(document.body, 0);
          window.__orchardRefs = { epoch: \(epoch), els: els };
          return JSON.stringify({ title: document.title || '', url: location.href, truncated: nodes.length >= MAX_NODES, nodes: nodes });
        })()
        """
    }

    /// Guard shared by all ref actions: the page-side registry must exist and
    /// match the snapshot's epoch (navigation wipes the JS world, a re-snapshot
    /// bumps the epoch), and the element must still be attached.
    private static func refLookup(epoch: Int, index: Int) -> String {
        """
          var S = window.__orchardRefs;
          if (!S || S.epoch !== \(epoch)) return JSON.stringify({ok:false, error:'stale'});
          var el = S.els[\(index)];
          if (!el || !el.isConnected) return JSON.stringify({ok:false, error:'stale'});
        """
    }

    static func click(epoch: Int, index: Int) -> String {
        """
        (function(){
        \(refLookup(epoch: epoch, index: index))
          try {
            if (el.scrollIntoView) el.scrollIntoView({block:'center', inline:'center'});
            if (typeof el.click === 'function') el.click();
            else el.dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true, view:window}));
            return JSON.stringify({ok:true});
          } catch (e) { return JSON.stringify({ok:false, error:String(e)}); }
        })()
        """
    }

    /// Replace the element's value. Uses the prototype's value setter so
    /// framework-controlled inputs (React et al.) observe the change, then fires
    /// input/change like a user edit would.
    static func fill(epoch: Int, index: Int, text: String) -> String {
        """
        (function(){
        \(refLookup(epoch: epoch, index: index))
          var v = \(literal(text));
          try {
            el.focus();
            if (el.isContentEditable) {
              el.textContent = v;
            } else if ('value' in el) {
              var proto = Object.getPrototypeOf(el), desc = null;
              while (proto && !desc) { desc = Object.getOwnPropertyDescriptor(proto, 'value'); proto = Object.getPrototypeOf(proto); }
              if (desc && desc.set) desc.set.call(el, v); else el.value = v;
            } else {
              return JSON.stringify({ok:false, error:'element is not fillable'});
            }
            el.dispatchEvent(new Event('input', {bubbles:true}));
            el.dispatchEvent(new Event('change', {bubbles:true}));
            return JSON.stringify({ok:true});
          } catch (e) { return JSON.stringify({ok:false, error:String(e)}); }
        })()
        """
    }

    /// Append text to a ref'd element, or to the focused element when
    /// `index < 0` (type-into-whatever-has-focus needs no snapshot).
    static func type(epoch: Int, index: Int, text: String) -> String {
        let acquire: String
        if index >= 0 {
            acquire = refLookup(epoch: epoch, index: index) + "\n  el.focus();"
        } else {
            acquire = """
              var el = document.activeElement;
              if (!el || el === document.body) return JSON.stringify({ok:false, error:'no focused element'});
            """
        }
        return """
        (function(){
        \(acquire)
          var v = \(literal(text));
          try {
            if (el.isContentEditable) {
              if (!document.execCommand || !document.execCommand('insertText', false, v)) el.textContent = (el.textContent || '') + v;
            } else if ('value' in el) {
              var next = (el.value || '') + v;
              var proto = Object.getPrototypeOf(el), desc = null;
              while (proto && !desc) { desc = Object.getOwnPropertyDescriptor(proto, 'value'); proto = Object.getPrototypeOf(proto); }
              if (desc && desc.set) desc.set.call(el, next); else el.value = next;
              el.dispatchEvent(new Event('input', {bubbles:true}));
            } else {
              return JSON.stringify({ok:false, error:'element does not accept text'});
            }
            return JSON.stringify({ok:true});
          } catch (e) { return JSON.stringify({ok:false, error:String(e)}); }
        })()
        """
    }

    /// Run a caller-supplied expression and JSON-encode the result. The
    /// expression is delivered as a string literal into `eval` so it cannot
    /// escape the wrapper; non-serializable results degrade to `String(r)`.
    static func eval(expression: String) -> String {
        """
        (function(){
          try {
            var r = eval(\(literal(expression)));
            var out;
            try { out = JSON.stringify({ok:true, value:(r === undefined ? null : r)}); }
            catch (_) { out = JSON.stringify({ok:true, value:String(r)}); }
            if (out === undefined) out = JSON.stringify({ok:true, value:null});
            return out;
          } catch (e) { return JSON.stringify({ok:false, error:String(e)}); }
        })()
        """
    }

    /// Installed as a document-start user script by the host: mirrors console
    /// calls and uncaught errors to the `orchardConsole` message handler. Public
    /// because the app-side host needs the source verbatim.
    public static let consoleCapture = """
        (function(){
          if (window.__orchardConsoleHooked) return; window.__orchardConsoleHooked = true;
          function post(level, args){
            try {
              var parts = [];
              for (var i = 0; i < args.length; i++) {
                var a = args[i];
                if (typeof a === 'string') parts.push(a);
                else { try { parts.push(JSON.stringify(a)); } catch (_) { parts.push(String(a)); } }
              }
              window.webkit.messageHandlers.orchardConsole.postMessage({level: level, text: parts.join(' ')});
            } catch (_) {}
          }
          ['log','info','warn','error','debug'].forEach(function(level){
            var original = console[level];
            console[level] = function(){ post(level, arguments); if (original) original.apply(console, arguments); };
          });
          window.addEventListener('error', function(e){ post('error', [String(e.message || e)]); });
          window.addEventListener('unhandledrejection', function(e){ post('error', ['Unhandled rejection: ' + String(e.reason)]); });
        })();
        """
}
