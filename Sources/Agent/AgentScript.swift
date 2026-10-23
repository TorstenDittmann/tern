/// The page-side half of the agent API. It runs in the private `tern-agent` content world, so page
/// scripts can't see it, call it or tamper with it. `bootstrap` evaluates to an object of functions;
/// `PageDriver` installs it once per document and calls one function per request.
enum AgentScript {
    static let bootstrap = #"""
    (() => {
      const refs = new Map();
      const refOf = new WeakMap();
      let nextRef = 1;

      const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK']);
      const INTERACTIVE = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox',
        'listbox', 'option', 'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox',
        'menuitemradio', 'treeitem', 'clickable']);
      // Roles whose text content is their name; we print the name and don't descend.
      const LEAF = new Set(['link', 'button', 'heading', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox',
        'listbox', 'slider', 'spinbutton', 'switch', 'img', 'option', 'tab', 'menuitem', 'menuitemcheckbox',
        'menuitemradio', 'treeitem', 'columnheader', 'clickable']);
      const NAMED_BY_CONTENT = new Set(['link', 'button', 'heading', 'option', 'tab', 'menuitem', 'menuitemcheckbox',
        'menuitemradio', 'treeitem', 'columnheader', 'clickable', 'switch']);
      const LANDMARKS = { NAV: 'navigation', MAIN: 'main', HEADER: 'banner', FOOTER: 'contentinfo',
        ASIDE: 'complementary', FORM: 'form', DIALOG: 'dialog' };
      const SEMANTIC = 'a[href],button,input:not([type=hidden]),select,textarea,summary,img,h1,h2,h3,h4,h5,h6,' +
        'ul,ol,table,nav,main,header,footer,aside,form,dialog,[role],[tabindex],[contenteditable=true],[onclick]';

      const clean = (s, max = 80) => {
        s = String(s ?? '').replace(/\s+/g, ' ').trim();
        return s.length > max ? s.slice(0, max - 1) + '…' : s;
      };
      const shown = (el) => !el.checkVisibility || el.checkVisibility({ visibilityProperty: true });

      function roleOf(el) {
        const explicit = el.getAttribute('role');
        if (explicit) return explicit.split(/\s+/)[0];
        const tag = el.tagName;
        switch (tag) {
          case 'A': return el.hasAttribute('href') ? 'link' : null;
          case 'BUTTON': case 'SUMMARY': return 'button';
          case 'SELECT': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
          case 'OPTION': return 'option';
          case 'TEXTAREA': return 'textbox';
          case 'IMG': return el.getAttribute('alt') === '' ? null : 'img';
          case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': return 'heading';
          case 'UL': case 'OL': return 'list';
          case 'LI': return 'listitem';
          case 'TABLE': return 'table';
          case 'TR': return 'row';
          case 'TH': return 'columnheader';
          case 'TD': return 'cell';
          case 'INPUT': {
            const type = (el.type || 'text').toLowerCase();
            if (type === 'hidden') return null;
            return { checkbox: 'checkbox', radio: 'radio', range: 'slider', number: 'spinbutton', search: 'searchbox',
              button: 'button', submit: 'button', reset: 'button', image: 'button', file: 'button' }[type] || 'textbox';
          }
        }
        if (LANDMARKS[tag]) return LANDMARKS[tag];
        if (el.isContentEditable && el.getAttribute('contenteditable') !== null) return 'textbox';
        if (el.hasAttribute('onclick') || el.getAttribute('tabindex') !== null && el.tabIndex >= 0) return 'clickable';
        return null;
      }

      function nameOf(el, role, forAudit = false) {
        const by = el.getAttribute('aria-labelledby');
        if (by) {
          const t = by.split(/\s+/).map(id => document.getElementById(id)?.innerText || '').join(' ');
          if (t.trim()) return clean(t);
        }
        const aria = el.getAttribute('aria-label');
        if (aria && aria.trim()) return clean(aria);
        if (el.labels && el.labels.length) {
          const t = [...el.labels].map(l => l.innerText).join(' ');
          if (t.trim()) return clean(t);
        }
        if (el.tagName === 'IMG') return clean(el.getAttribute('alt'));
        if (el.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes(el.type)) return clean(el.value || (forAudit ? '' : el.type));
        if (NAMED_BY_CONTENT.has(role)) {
          const t = clean(el.innerText || el.textContent);
          if (t) return t;
          const img = el.querySelector('img[alt]');
          if (img && img.alt.trim()) return clean(img.alt);
        }
        if (!forAudit && ['textbox', 'searchbox', 'combobox', 'spinbutton'].includes(role)) return clean(el.placeholder || el.title);
        return clean(el.title);
      }

      function remember(el) {
        const known = refOf.get(el);
        if (known && refs.has(known)) return known;
        const ref = 'e' + nextRef++;
        refs.set(ref, new WeakRef(el));
        refOf.set(el, ref);
        return ref;
      }

      function element(ref) {
        const el = refs.get(ref)?.deref();
        if (!el || !el.isConnected) throw new Error('stale ref ' + ref + ': take a new snapshot');
        return el;
      }

      function root(scope) {
        const el = scope ? document.querySelector(scope) : document.body;
        if (!el) throw new Error('No element matches ' + scope);
        return el;
      }

      function snapshot({ scope, maxLines = 1500 } = {}) {
        // Refs stay stable for the document's life, so a scoped snapshot never rebinds older ones.
        for (const [ref, weak] of refs) {
          const el = weak.deref();
          if (!el || !el.isConnected) refs.delete(ref);
        }
        const lines = [];
        const indent = (d) => '  '.repeat(d);
        const walk = (el, depth) => {
          if (lines.length >= maxLines || SKIP.has(el.tagName)) return;
          if (el.getAttribute('aria-hidden') === 'true' || !shown(el)) return;
          const role = roleOf(el);
          let childDepth = depth;
          if (role) {
            const name = nameOf(el, role);
            let line = indent(depth) + '- ' + role + (name ? ' ' + JSON.stringify(name) : '');
            if (role === 'heading') line += ` [level=${el.getAttribute('aria-level') || el.tagName[1] || 2}]`;
            if (INTERACTIVE.has(role)) line += ` [ref=${remember(el)}]`;
            if (['checkbox', 'radio', 'switch'].includes(role)) {
              line += ` [checked=${'checked' in el ? el.checked : el.getAttribute('aria-checked') === 'true'}]`;
            }
            if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' [disabled]';
            if (el.type === 'password') line += ' [type=password]';
            else if (['textbox', 'searchbox', 'spinbutton', 'slider'].includes(role)) {
              const v = 'value' in el ? el.value : el.innerText;
              if (v) line += ' [value=' + JSON.stringify(clean(v, 60)) + ']';
            }
            if (el.tagName === 'SELECT') {
              const options = [...el.options].slice(0, 25).map(o => clean(o.label || o.text, 40));
              line += ' [options=' + JSON.stringify(options) + ']';
              if (el.selectedOptions.length) line += ' [selected=' + JSON.stringify([...el.selectedOptions].map(o => o.value)) + ']';
            }
            if (role === 'link') line += ' -> ' + el.getAttribute('href');
            lines.push(line);
            childDepth = depth + 1;
            if (LEAF.has(role)) return;
          }
          // Plain content with nothing semantic inside collapses to one text line.
          if (!el.shadowRoot && !el.querySelector(SEMANTIC)) {
            const t = clean(el.innerText, 300);
            if (t) lines.push(indent(childDepth) + '- text ' + JSON.stringify(t));
            return;
          }
          for (const node of el.childNodes) {
            if (lines.length >= maxLines) break;
            if (node.nodeType === Node.TEXT_NODE) {
              const t = clean(node.textContent, 300);
              if (t) lines.push(indent(childDepth) + '- text ' + JSON.stringify(t));
            } else if (node.nodeType === Node.ELEMENT_NODE) {
              walk(node, childDepth);
            }
          }
          if (el.shadowRoot) for (const child of el.shadowRoot.children) walk(child, childDepth);
        };
        walk(root(scope), 0);
        if (lines.length >= maxLines) lines.push(`- … (cut at ${maxLines} lines; pass scope to narrow it)`);
        return { url: location.href, title: document.title, snapshot: lines.join('\n') };
      }

      function rect({ ref }) {
        const el = element(ref);
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const r = el.getBoundingClientRect();
        const x = r.left + r.width / 2, y = r.top + r.height / 2;
        const hit = document.elementFromPoint(x, y);
        return { x, y, left: r.left, top: r.top, width: r.width, height: r.height,
          covered: !!hit && hit !== el && !el.contains(hit) && !hit.contains(el) };
      }

      // Lets PageDriver tell whether a native click reached the element.
      let clicked = null;
      function armClick({ ref }) {
        const el = element(ref);
        clicked = false;
        el.addEventListener('click', () => { clicked = true; }, { once: true, capture: true });
        return true;
      }
      function wasClicked() { return clicked === true; }

      function click({ ref }) {
        const el = element(ref);
        el.scrollIntoView({ block: 'center', behavior: 'instant' });
        el.focus?.();
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
          el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
        }
        el.click();
        return true;
      }

      function focus({ ref, clear }) {
        const el = element(ref);
        el.scrollIntoView({ block: 'center', behavior: 'instant' });
        el.focus();
        if (clear) {
          if (typeof el.select === 'function') el.select();
          else if (el.isContentEditable) document.getSelection().selectAllChildren(el);
        } else if (typeof el.setSelectionRange === 'function') {
          try { el.setSelectionRange(el.value.length, el.value.length); } catch {}
        }
        return document.activeElement === el || el.contains(document.activeElement);
      }

      function valueOf({ ref }) {
        const el = element(ref);
        return 'value' in el && el.tagName !== 'BUTTON' ? String(el.value) : el.innerText;
      }

      function fill({ ref, text, clear }) {
        const el = element(ref);
        focus({ ref, clear });
        if (typeof document.execCommand === 'function' && document.execCommand('insertText', false, text)) return true;
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, (clear ? '' : el.value) + text);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      }

      function pressFallback({ key }) {
        const el = document.activeElement || document.body;
        const names = { enter: 'Enter', return: 'Enter', tab: 'Tab', escape: 'Escape', space: ' ', backspace: 'Backspace',
          delete: 'Delete', left: 'ArrowLeft', right: 'ArrowRight', up: 'ArrowUp', down: 'ArrowDown' };
        const k = names[key] || key;
        for (const type of ['keydown', 'keypress', 'keyup']) {
          el.dispatchEvent(new KeyboardEvent(type, { key: k, bubbles: true, cancelable: true }));
        }
        if (k === 'Enter' && el.form) el.form.requestSubmit();
        return true;
      }

      function select({ ref, values }) {
        const el = element(ref);
        if (el.tagName !== 'SELECT') throw new Error(ref + ' is not a <select>');
        const want = new Set(values);
        for (const o of el.options) o.selected = want.has(o.value) || want.has(o.label) || want.has(o.text.trim());
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return [...el.selectedOptions].map(o => o.value);
      }

      function scroll({ ref, dx = 0, dy = 0 }) {
        if (ref) element(ref).scrollIntoView({ block: 'center', behavior: 'instant' });
        else window.scrollBy(dx, dy);
        return { scrollX, scrollY };
      }

      function check({ text, selector }) {
        if (selector && !document.querySelector(selector)) return false;
        if (text && !(document.body?.innerText || '').includes(text)) return false;
        return true;
      }

      const BLOCK = /^(P|DIV|SECTION|ARTICLE|MAIN|HEADER|FOOTER|NAV|ASIDE|UL|OL|LI|H[1-6]|PRE|BLOCKQUOTE|TABLE|THEAD|TBODY|TFOOT|TR|FORM|FIGURE|DL|DT|DD|BODY|DETAILS|DIALOG)$/;
      function inline(node) {
        if (node.nodeType === Node.TEXT_NODE) return node.textContent.replace(/\s+/g, ' ');
        if (node.nodeType !== Node.ELEMENT_NODE || SKIP.has(node.tagName) || !shown(node)) return '';
        const inner = [...node.childNodes].map(inline).join('');
        switch (node.tagName) {
          case 'A': return node.getAttribute('href') ? `[${inner.trim()}](${node.href})` : inner;
          case 'STRONG': case 'B': return inner.trim() ? `**${inner.trim()}**` : '';
          case 'EM': case 'I': return inner.trim() ? `*${inner.trim()}*` : '';
          case 'CODE': return '`' + inner + '`';
          case 'IMG': return node.alt ? `![${node.alt}](${node.src})` : '';
          case 'BR': return '\n';
          case 'SELECT': case 'TEXTAREA': return '';
          default: return inner;
        }
      }
      function markdown(start) {
        const lines = [];
        const tidy = (s) => s.replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').trim();
        const walk = (el, indent) => {
          if (SKIP.has(el.tagName) || !shown(el)) return;
          const tag = el.tagName;
          if (/^H[1-6]$/.test(tag)) { lines.push('', '#'.repeat(+tag[1]) + ' ' + tidy(inline(el)), ''); return; }
          if (tag === 'PRE') { lines.push('', '```', el.innerText, '```', ''); return; }
          if (tag === 'LI') {
            const own = [...el.childNodes].filter(n => !(n.nodeType === 1 && /^(UL|OL)$/.test(n.tagName))).map(inline).join('');
            lines.push(indent + '- ' + tidy(own));
            for (const c of el.children) if (/^(UL|OL)$/.test(c.tagName)) walk(c, indent + '  ');
            return;
          }
          if (tag === 'TR') { lines.push('| ' + [...el.cells].map(c => tidy(inline(c))).join(' | ') + ' |'); return; }
          if ([...el.children].some(c => BLOCK.test(c.tagName))) {
            let run = '';
            for (const n of el.childNodes) {
              if (n.nodeType === 1 && BLOCK.test(n.tagName)) {
                if (tidy(run)) lines.push(tidy(run), '');
                run = '';
                walk(n, indent);
              } else run += inline(n);
            }
            if (tidy(run)) lines.push(tidy(run), '');
            return;
          }
          const s = tidy(inline(el));
          if (s) lines.push(s, '');
        };
        walk(start, '');
        return lines.join('\n').replace(/\n{3,}/g, '\n\n').trim();
      }

      function text({ format = 'text', scope }) {
        const el = root(scope);
        if (format === 'html') return { text: scope ? el.outerHTML : document.documentElement.outerHTML };
        if (format === 'markdown') return { text: markdown(el) };
        if (format !== 'text') throw new Error('format must be text, markdown or html');
        return { text: el.innerText };
      }

      function cssPath(el) {
        const parts = [];
        for (let e = el; e && e.nodeType === 1 && parts.length < 4; e = e.parentElement) {
          if (e.id) { parts.unshift('#' + CSS.escape(e.id)); break; }
          const same = e.parentElement ? [...e.parentElement.children].filter(c => c.tagName === e.tagName) : [];
          parts.unshift(e.tagName.toLowerCase() + (same.length > 1 ? `:nth-of-type(${same.indexOf(e) + 1})` : ''));
        }
        return parts.join(' > ');
      }

      // A small, dependency-free set of WCAG checks. Not a replacement for a full audit.
      function audit({ scope } = {}) {
        snapshot({ scope }); // assigns refs so issues can point at them
        const start = root(scope);
        const issues = [];
        const add = (rule, el, message) => {
          const ref = refOf.get(el) ?? null;
          issues.push({ rule, message, ref, selector: cssPath(el), html: clean(el.outerHTML, 120) });
        };
        const all = (sel) => [...start.querySelectorAll(sel)].filter(e => shown(e) && !e.closest('[aria-hidden=true]'));

        if (!scope) {
          if (!document.documentElement.getAttribute('lang')) add('html-lang', document.documentElement, 'The page has no lang attribute.');
          if (!document.title.trim()) add('document-title', document.documentElement, 'The page has no title.');
        }
        for (const img of all('img')) {
          if (!img.hasAttribute('alt') && img.getAttribute('role') !== 'presentation' && !img.getAttribute('aria-label')) {
            add('image-alt', img, 'Image has no alt text.');
          }
        }
        for (const el of all('input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=reset]):not([type=image]), select, textarea')) {
          if (!nameOf(el, roleOf(el), true)) add('label', el, 'Form field has no label.');
        }
        for (const el of all('button, [role=button], input[type=submit], input[type=button]')) {
          if (!nameOf(el, 'button', true)) add('button-name', el, 'Button has no accessible name.');
        }
        for (const el of all('a[href]')) {
          if (!nameOf(el, 'link', true)) add('link-name', el, 'Link has no accessible name.');
        }
        let last = 0;
        for (const h of all('h1, h2, h3, h4, h5, h6')) {
          const level = +h.tagName[1];
          if (last && level > last + 1) add('heading-order', h, `Heading jumps from h${last} to h${level}.`);
          last = level;
        }
        const seen = new Map();
        for (const el of start.querySelectorAll('[id]')) seen.set(el.id, (seen.get(el.id) || 0) + 1);
        for (const [id, n] of seen) if (n > 1) add('duplicate-id', document.getElementById(id), `id "${id}" is used ${n} times.`);
        for (const el of all('[tabindex]')) if (el.tabIndex > 0) add('tabindex', el, 'Positive tabindex changes the tab order.');
        return { issues, count: issues.length,
          rules: ['html-lang', 'document-title', 'image-alt', 'label', 'button-name', 'link-name', 'heading-order', 'duplicate-id', 'tabindex'] };
      }

      return { snapshot, rect, armClick, wasClicked, click, focus, valueOf, fill, pressFallback, select, scroll, check, text, audit };
    })()
    """#

    /// Body passed to `callAsyncJavaScript` with `method` and `args` as arguments.
    static let call = """
    const tern = globalThis.__tern || (globalThis.__tern = \(bootstrap));
    const fn = tern[method];
    if (!fn) throw new Error('Unknown page method ' + method);
    const result = await fn(args);
    return result === undefined ? null : result;
    """
}
