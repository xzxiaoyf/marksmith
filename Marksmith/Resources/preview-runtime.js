/*
 * Marksmith preview runtime.
 * Shared by the in-app preview shell and by exported standalone HTML files,
 * so math, code highlighting and diagrams behave identically in both.
 */
(function () {
    'use strict';

    var currentTheme = 'light';
    window.marksmithRenderDone = false;
    window._marksmithRenderPromise = Promise.resolve();

    try {
        mermaid.initialize({
            startOnLoad: false,
            theme: 'default',
            securityLevel: 'strict',
            flowchart: { useMaxWidth: true }
        });
    } catch (e) {
        console.warn('[Marksmith] mermaid init failed:', e);
    }

    function safe(label, fn) {
        try { fn(); } catch (e) { console.warn('[Marksmith] ' + label + ' failed:', e); }
    }

    function renderMath(root) {
        if (typeof renderMathInElement === 'function') {
            safe('katex-auto', function () {
                renderMathInElement(root, {
                    delimiters: [
                        { left: '$$', right: '$$', display: true },
                        { left: '\\[', right: '\\]', display: true },
                        { left: '\\(', right: '\\)', display: false }
                    ],
                    throwOnError: false
                });
            });
        }
        if (typeof katex !== 'object') { return; }
        safe('katex-inline', function () { renderGuardedInlineMath(root); });
    }

    /* Single-$ math only when the span looks like math, not "$5 and $10". */
    function renderGuardedInlineMath(root) {
        var INLINE = /\$(?=\S)(?!\d)((?:[^$\\\n]|\\.)*?[^\s$])\$/g;
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: function (node) {
                if (!node.nodeValue || node.nodeValue.indexOf('$') === -1) {
                    return NodeFilter.FILTER_REJECT;
                }
                for (var p = node.parentNode; p && p !== root; p = p.parentNode) {
                    var tag = p.tagName;
                    if (tag === 'CODE' || tag === 'PRE' || tag === 'SCRIPT' ||
                        tag === 'STYLE' || tag === 'TEXTAREA') {
                        return NodeFilter.FILTER_REJECT;
                    }
                    if (p.classList && (p.classList.contains('katex') ||
                                        p.classList.contains('marksmith-mermaid'))) {
                        return NodeFilter.FILTER_REJECT;
                    }
                }
                return NodeFilter.FILTER_ACCEPT;
            }
        });

        var targets = [], n;
        while ((n = walker.nextNode())) { targets.push(n); }

        targets.forEach(function (textNode) {
            var text = textNode.nodeValue;
            INLINE.lastIndex = 0;
            var m = INLINE.exec(text);
            if (m === null) { return; }

            var frag = document.createDocumentFragment();
            var last = 0;
            do {
                if (m.index > last) {
                    frag.appendChild(document.createTextNode(text.slice(last, m.index)));
                }
                var span = document.createElement('span');
                safe('katex-span', function () {
                    katex.render(m[1], span, { throwOnError: false, displayMode: false });
                });
                if (!span.hasChildNodes()) { span.textContent = m[0]; }
                frag.appendChild(span);
                last = m.index + m[0].length;
            } while ((m = INLINE.exec(text)) !== null);

            if (last < text.length) {
                frag.appendChild(document.createTextNode(text.slice(last)));
            }
            textNode.parentNode.replaceChild(frag, textNode);
        });
    }

    function renderCode(root) {
        if (typeof hljs === 'undefined') { return; }
        safe('highlight.js', function () {
            root.querySelectorAll('pre code').forEach(function (block) {
                if (block.classList.contains('language-mermaid')) { return; }
                if (block.dataset.marksmithHighlighted === '1') { return; }
                hljs.highlightElement(block);
                block.dataset.marksmithHighlighted = '1';
            });
        });
    }

    function renderDiagrams(root) {
        if (typeof mermaid === 'undefined' || typeof mermaid.run !== 'function') {
            return Promise.resolve();
        }
        var pending = [];
        safe('mermaid', function () {
            root.querySelectorAll('pre > code.language-mermaid').forEach(function (codeEl) {
                var pre = codeEl.parentElement;
                var wrapper = document.createElement('div');
                wrapper.className = 'marksmith-mermaid';
                var diagram = document.createElement('div');
                diagram.className = 'mermaid';
                diagram.textContent = codeEl.textContent;
                wrapper.appendChild(diagram);
                pre.parentNode.replaceChild(wrapper, pre);
                pending.push(diagram);
            });
        });
        if (pending.length === 0) { return Promise.resolve(); }
        return mermaid.run({ nodes: pending }).catch(function (e) {
            console.warn('[Marksmith] mermaid render failed:', e);
        });
    }

    /** Swift injects already-rendered (and escaped) HTML here. */
    window.updateContent = function (html) {
        var content = document.getElementById('content');
        if (!content) { return; }
        var scrollY = window.pageYOffset || document.documentElement.scrollTop || 0;
        window.marksmithRenderDone = false;
        content.innerHTML = html;
        renderMath(content);
        renderCode(content);
        window.scrollTo(0, scrollY);
        window._marksmithRenderPromise = Promise.resolve(renderDiagrams(content))
            .catch(function (e) { console.warn('[Marksmith] render pipeline:', e); })
            .then(function () {
                window.marksmithRenderDone = true;
                window.scrollTo(0, scrollY);
            });
    };

    window.setTheme = function (theme) {
        currentTheme = (theme === 'dark') ? 'dark' : 'light';
        var themeLink = document.getElementById('marksmith-theme');
        var hljsLink = document.getElementById('marksmith-hljs-theme');
        if (themeLink) {
            themeLink.href = currentTheme === 'dark'
                ? 'preview-dark.css' : 'preview-light.css';
        }
        if (hljsLink) {
            hljsLink.href = currentTheme === 'dark'
                ? 'vendor/highlight/github-dark.min.css'
                : 'vendor/highlight/github.min.css';
        }
        try {
            mermaid.initialize({
                startOnLoad: false,
                theme: currentTheme === 'dark' ? 'dark' : 'default',
                securityLevel: 'strict'
            });
        } catch (e) { /* older mermaid builds */ }
    };

    /** PDF exporter waits on this so Mermaid SVGs are complete before printing. */
    window.marksmithWaitForRender = function () {
        return window._marksmithRenderPromise || Promise.resolve();
    };

    document.addEventListener('click', function (event) {
        var a = event.target && event.target.closest ? event.target.closest('a') : null;
        if (!a || !a.href) { return; }
        if (/^https?:/i.test(a.getAttribute('href') || '')) {
            event.preventDefault();
            var bridge = window.webkit && window.webkit.messageHandlers &&
                         window.webkit.messageHandlers.marksmithLink;
            if (bridge) { bridge.postMessage(a.href); }
            else { window.open(a.href, '_blank', 'noopener'); }
        }
    });
})();
