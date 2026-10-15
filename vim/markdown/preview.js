/* Offline Markdown rendering. No document scripts or remote dependencies are executed. */
(() => {
  'use strict';
  const article = document.getElementById('document');
  const outline = document.getElementById('outline');
  const followButton = document.getElementById('follow');
  const prefix = location.pathname;
  let follow = true;
  let revision = -1;
  let documentRevision = -1;
  let lastLine = -1;
  let currentBase = '';
  let sourceNodes = [];
  const md = window.markdownit({
    html: false, linkify: true, breaks: false,
    highlight(code, language) {
      if (language && window.hljs.getLanguage(language)) {
        return window.hljs.highlight(code, {language, ignoreIllegals: true}).value;
      }
      return '';
    },
  });
  const escape = md.utils.escapeHtml;
  function math(tex, displayMode) {
    try {
      return window.katex.renderToString(tex, {
        displayMode, throwOnError: true, trust: false, strict: 'ignore', maxExpand: 1000,
      });
    } catch (error) {
      return `<code class="math-error" title="${escape(error.message)}">${escape(tex)}</code>`;
    }
  }
  md.inline.ruler.after('escape', 'math_inline', (state, silent) => {
    const start = state.pos;
    if (state.src[start] !== '$' || /\s/.test(state.src[start + 1] || ' ')
        || state.src[start + 1] === '$') return false;
    let end = start + 1;
    while ((end = state.src.indexOf('$', end)) >= 0) {
      let backslashes = 0;
      for (let i = end - 1; state.src[i] === '\\'; i--) backslashes++;
      if (backslashes % 2 === 0) break;
      end++;
    }
    if (end < 0 || /\s/.test(state.src[end - 1]) || /\d/.test(state.src[end + 1] || '')) return false;
    if (!silent) state.push('math_inline', '', 0).content = state.src.slice(start + 1, end);
    state.pos = end + 1;
    return true;
  });
  md.renderer.rules.math_inline = (tokens, index) => math(tokens[index].content, false);
  md.block.ruler.before('fence', 'math_block', (state, start, end, silent) => {
    const first = state.src.slice(state.bMarks[start] + state.tShift[start], state.eMarks[start]);
    if (!first.startsWith('$$')) return false;
    let body = first.slice(2);
    let next = start + 1;
    if (body.endsWith('$$')) body = body.slice(0, -2);
    else {
      let closed = false;
      for (; next < end; next++) {
        const line = state.src.slice(state.bMarks[next] + state.tShift[next], state.eMarks[next]);
        if (line.trimEnd().endsWith('$$')) {
          body += '\n' + line.trimEnd().slice(0, -2);
          next++;
          closed = true;
          break;
        }
        body += '\n' + line;
      }
      if (!closed) return false;
    }
    if (!silent) {
      const token = state.push('math_block', 'div', 0);
      token.block = true;
      token.content = body;
      token.map = [start, next];
      state.line = next;
    }
    return true;
  });
  md.renderer.rules.math_block = (tokens, index) =>
    `<div class="math-display" data-line="${tokens[index].map[0] + 1}">${math(tokens[index].content, true)}</div>`;
  md.core.ruler.after('inline', 'source_and_headings', state => {
    const slugs = new Map();
    state.tokens.forEach((token, index) => {
      if (token.map && token.type !== 'inline' && (token.nesting === 1 || token.nesting === 0)) {
        token.attrSet('data-line', String(token.map[0] + 1));
      }
      if (token.type === 'heading_open') {
        const text = (state.tokens[index + 1].children || [])
          .filter(child => ['text', 'code_inline', 'math_inline'].includes(child.type))
          .map(child => child.content).join('');
        const base = text.toLowerCase().replace(/[^\p{L}\p{N}_ -]/gu, '').replace(/ /g, '-') || 'section';
        const count = slugs.get(base) || 0;
        slugs.set(base, count + 1);
        token.attrSet('id', base + (count ? '-' + count : ''));
      }
      if (token.type === 'inline' && index >= 2 && state.tokens[index - 2].type === 'list_item_open') {
        const children = token.children;
        const task = children?.[0]?.type === 'text' && /^\[([ xX])\]\s+/.exec(children[0].content);
        if (task) {
          children[0].content = children[0].content.slice(task[0].length);
          const checkbox = new state.Token('html_inline', '', 0);
          checkbox.content = `<input type="checkbox" disabled aria-label="任务" ${task[1] !== ' ' ? 'checked' : ''}>`;
          children.unshift(checkbox);
          state.tokens[index - 2].attrJoin('class', 'task-list-item');
        }
      }
      if (token.type === 'inline' && index >= 2 && state.tokens[index - 2].type === 'blockquote_open') {
        const callout = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\s*\n|\s*$)/.exec(token.content);
        if (callout && token.children?.[0]?.type === 'text') {
          token.children[0].content = token.children[0].content.replace(/^\[![A-Z]+\]/, '');
          const title = new state.Token('html_inline', '', 0);
          title.content = `<div class="callout-title">${callout[1]}</div>`;
          token.children.unshift(title);
          state.tokens[index - 2].attrJoin('class', 'callout callout-' + callout[1].toLowerCase());
        }
      }
    });
  });
  const defaultFence = md.renderer.rules.fence;
  md.renderer.rules.fence = (tokens, index, options, env, renderer) => {
    const token = tokens[index];
    const result = defaultFence(tokens, index, options, env, renderer);
    const language = token.info.trim().split(/\s+/)[0] || 'text';
    return result.replace('<pre', `<pre data-line="${token.map[0] + 1}" data-language="${escape(language)}"`);
  };
  const defaultImage = md.renderer.rules.image;
  md.renderer.rules.image = (tokens, index, options, env, renderer) => {
    const token = tokens[index];
    const src = token.attrGet('src') || '';
    if (src && !/^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(src)) {
      const base = `${location.origin}${prefix}media/${currentBase ? currentBase.split('/').map(encodeURIComponent).join('/') + '/' : ''}`;
      const url = new URL(src.replace(/^\//, ''), src.startsWith('/') ? location.origin + prefix + 'media/' : base);
      token.attrSet('src', url.href);
    }
    return defaultImage(tokens, index, options, env, renderer);
  };
  function render(state) {
    currentBase = state.base;
    const front = /^---\n([\s\S]*?)\n(?:---|\.\.\.)\s*(?:\n|$)/.exec(state.text);
    let source = state.text;
    let metadata = '';
    if (front) {
      metadata = `<details class="frontmatter"><summary>文档属性</summary><pre>${escape(front[1])}</pre></details>`;
      // Preserve source line numbers after removing front matter from the rendered body.
      source = '\n'.repeat(front[0].split('\n').length - 1) + source.slice(front[0].length);
    }
    article.innerHTML = metadata + (md.render(source) || '<div class="empty-state">开始写作<small> · 文档为空</small></div>');
    document.getElementById('filename').textContent = state.name;
    document.title = state.name + ' · TokyoNight';
    article.querySelectorAll('table').forEach(table => {
      const wrapper = document.createElement('div');
      wrapper.className = 'table-scroll';
      table.before(wrapper);
      wrapper.append(table);
    });
    article.querySelectorAll('pre:has(code)').forEach(pre => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'copy-code';
      button.textContent = '复制';
      button.addEventListener('click', async () => {
        try {
          await navigator.clipboard.writeText(pre.querySelector('code').textContent);
          button.textContent = '已复制';
        } catch { button.textContent = '复制失败'; }
        setTimeout(() => { button.textContent = '复制'; }, 1800);
      });
      pre.prepend(button);
    });
    article.querySelectorAll('a').forEach(link => {
      if (/^https?:/i.test(link.getAttribute('href'))) {
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
      } else if (!link.getAttribute('href')?.startsWith('#')) {
        link.addEventListener('click', event => {
          event.preventDefault();
          document.getElementById('connection').lastChild.textContent = '在 Vim 中用 Space m l 打开本地链接';
        });
      }
    });
    outline.replaceChildren();
    const headings = [...article.querySelectorAll('h1,h2,h3,h4,h5,h6')];
    const minimum = Math.min(...headings.map(heading => Number(heading.tagName[1])), 6);
    headings.forEach(heading => {
      const link = document.createElement('a');
      link.href = '#' + encodeURIComponent(heading.id);
      link.textContent = heading.textContent;
      link.style.paddingLeft = (10 + (Number(heading.tagName[1]) - minimum) * 12) + 'px';
      outline.append(link);
    });
    document.getElementById('heading-count').textContent = String(headings.length);
    const chars = [...state.text.replace(/\s/g, '')].length;
    const lines = state.text.split('\n').length;
    document.getElementById('statistics').textContent = `${chars.toLocaleString()} 字符 · ${lines.toLocaleString()} 行`;
    sourceNodes = [...article.querySelectorAll('[data-line]')]
      .sort((a, b) => Number(a.dataset.line) - Number(b.dataset.line));
    updateOutline();
  }
  function scrollToSource(line) {
    if (!follow || !sourceNodes.length) return;
    let node = sourceNodes[0];
    let next;
    for (const candidate of sourceNodes) {
      if (Number(candidate.dataset.line) <= line) node = candidate;
      else { next = candidate; break; }
    }
    const top = node.getBoundingClientRect().top + window.scrollY;
    let offset = 0;
    if (next && Number(next.dataset.line) > Number(node.dataset.line)) {
      const span = next.getBoundingClientRect().top + window.scrollY - top;
      offset = Math.max(0, span) * (line - Number(node.dataset.line))
        / (Number(next.dataset.line) - Number(node.dataset.line));
    }
    window.scrollTo({top: Math.max(0, top + offset - 120), behavior: 'instant'});
  }
  function updateOutline() {
    const headings = [...article.querySelectorAll('h1,h2,h3,h4,h5,h6')];
    let active = headings[0];
    for (const heading of headings) if (heading.getBoundingClientRect().top <= 160) active = heading;
    [...outline.children].forEach((link, index) => link.classList.toggle('active', headings[index] === active));
  }
  async function poll() {
    const connection = document.getElementById('connection');
    try {
      const response = await fetch(`${prefix}state?document=${documentRevision}&revision=${revision}`, {cache: 'no-store'});
      if (!response.ok) throw new Error(String(response.status));
      if (response.status === 204) return;
      const state = await response.json();
      connection.classList.remove('offline');
      connection.lastChild.textContent = '实时预览';
      if (state.revision !== revision) {
        const changed = state.document !== documentRevision;
        if (changed) render(state);
        if (changed || state.line !== lastLine) scrollToSource(state.line);
        revision = state.revision;
        documentRevision = state.document;
        lastLine = state.line;
      }
    } catch {
      connection.classList.add('offline');
      connection.lastChild.textContent = '预览已停止';
    } finally { setTimeout(poll, document.hidden ? 1500 : 250); }
  }
  followButton.addEventListener('click', () => {
    follow = !follow;
    followButton.setAttribute('aria-pressed', String(follow));
    followButton.textContent = follow ? '跟随光标' : '自由阅读';
    if (follow) scrollToSource(lastLine);
  });
  document.getElementById('outline-toggle').addEventListener('click', event => {
    if (matchMedia('(max-width: 760px)').matches) {
      event.currentTarget.setAttribute('aria-expanded', String(document.body.classList.toggle('mobile-outline')));
    } else {
      event.currentTarget.setAttribute('aria-expanded', String(!document.body.classList.toggle('hide-outline')));
    }
  });
  document.getElementById('print').addEventListener('click', () => window.print());
  window.addEventListener('scroll', updateOutline, {passive: true});
  poll();
})();
