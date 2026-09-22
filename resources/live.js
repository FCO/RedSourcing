/* SSE carries invalidation signals; HTMX 4 fetches and morphs server-rendered HTML. */
(() => {
  let selectedFlowId = '';
  let dismissedFlowId = '';
  const clearPreview = () => {
    if (selectedFlowId) dismissedFlowId = selectedFlowId;
    selectedFlowId = '';
    document.querySelectorAll('.flow-preview').forEach(preview => {
      preview.querySelector('.flow-inspector').hidden = true;
      preview.querySelector('.flow-preview-empty').hidden = false;
      preview.querySelector('.flow-preview-close').hidden = true;
    });
    document.querySelectorAll('.flow-node.related, .flow-path.active, .flow-wire.active').forEach(element =>
      element.classList.remove('related', 'active'));
  };
  const showInspector = node => {
    if (dismissedFlowId === node.dataset.flowNode) return;
    const details = node.parentElement.querySelector('.flow-node-details');
    const preview = node.closest('.flow-workspace')?.querySelector('.flow-preview');
    if (!details || !preview) return;
    const inspector = preview.querySelector('.flow-inspector');
    inspector.innerHTML = details.innerHTML;
    inspector.hidden = false;
    preview.querySelector('.flow-preview-empty').hidden = true;
    preview.querySelector('.flow-preview-close').hidden = false;
    selectedFlowId = node.dataset.flowNode;
    node.setAttribute('aria-describedby', inspector.id);
  };
  const cubic = (a, b, c, d) => `C ${b.join(' ')} ${c.join(' ')} ${d.join(' ')}`;
  // A restrained S: control points follow the diagonal instead of making
  // horizontal handles that fold sharply when endpoints are far apart in Y.
  const gentleControls = (a, b) => {
    const dx = b[0] - a[0], dy = b[1] - a[1];
    return [[a[0] + dx * .32, a[1] + dy * .23],
      [b[0] - dx * .32, b[1] - dy * .23]];
  };
  document.addEventListener('keydown', event => { if (event.key === 'Escape') clearPreview(); });
  const drawFlow = () => {
    document.querySelectorAll('.flow-board').forEach(board => {
      const svg = board.querySelector('.flow-connectors');
      if (!svg) return;
      svg.replaceChildren();
      const nodes = new Map([...board.querySelectorAll('[data-flow-node]')].map(node => [node.dataset.flowNode, node]));
      const edges = [...board.querySelectorAll('[data-flow-source]')].filter(edge =>
        nodes.has(edge.dataset.flowSource) && nodes.has(edge.dataset.flowTarget))
        .sort((a, b) => `${a.dataset.flowSource}/${a.dataset.flowTarget}`.localeCompare(`${b.dataset.flowSource}/${b.dataset.flowTarget}`));
      const routes = edges.map(edge => {
        const source = nodes.get(edge.dataset.flowSource), target = nodes.get(edge.dataset.flowTarget);
        const sourceStage = Number(source.dataset.flowStage), targetStage = Number(target.dataset.flowStage);
        const forward = targetStage > sourceStage, sameStage = targetStage === sourceStage;
        return {edge, source, target, sourceStage, targetStage, forward, sameStage,
          sourceSide: forward || sameStage ? 'right' : 'left', targetSide: forward ? 'left' : 'right'};
      });
      board.closest('.flow-workspace').classList.toggle('flow-crowded', routes.length >= 18);
      const minColumnWidth = parseFloat(getComputedStyle(board).getPropertyValue('--flow-min-column-width')) || 180;
      // Incoming and outgoing links share one port allocator on each card edge.
      // Separate allocators used to put unrelated arrowheads/tails on top of each other.
      const ports = new Map([...nodes.values()].map(node => [node, {left: [], right: []}]));
      routes.forEach(route => {
        route.sourcePort = {route, other: route.target};
        route.targetPort = {route, other: route.source};
        ports.get(route.source)[route.sourceSide].push(route.sourcePort);
        ports.get(route.target)[route.targetSide].push(route.targetPort);
      });
      nodes.forEach(node => {
        const count = Math.max(ports.get(node).left.length, ports.get(node).right.length);
        node.style.minHeight = count > 5 ? `${64 + (count - 1) * 14}px` : '';
      });
      // Keep the room around busy card edges, without routing links up to
      // overhead lanes. Same-column arcs share the same spacing budget.
      const columns = board.querySelectorAll('.flow-stage').length;
      const gapCounts = Array(columns).fill(0), arcs = Array.from({length: columns}, () => []);
      routes.forEach(route => {
        if (route.sameStage) {
          route.arcIndex = arcs[route.sourceStage].length;
          arcs[route.sourceStage].push(route);
          gapCounts[route.sourceStage]++;
        } else if (Math.abs(route.targetStage - route.sourceStage) > 1) {
          gapCounts[route.sourceSide === 'right' ? route.sourceStage : route.sourceStage - 1]++;
          gapCounts[route.targetSide === 'right' ? route.targetStage : route.targetStage - 1]++;
        }
      });
      const gapWidths = gapCounts.map(count => Math.max(56, 40 + (count - 1) * 18));
      const tracks = [];
      for (let column = 0; column < columns; column++) {
        tracks.push(`minmax(${minColumnWidth}px,1fr)`);
        if (column < columns - 1) tracks.push(`${gapWidths[column]}px`);
      }
      board.style.gridTemplateColumns = tracks.join(' ');
      const extraRight = arcs[columns - 1].length ? gapWidths[columns - 1] : 0;
      board.style.minWidth = `${minColumnWidth * columns
        + gapWidths.slice(0, columns - 1).reduce((a, b) => a + b, 0) + extraRight}px`;
      board.style.paddingRight = `${extraRight}px`;
      const origin = board.getBoundingClientRect();
      const boxes = new Map([...nodes.values()].map(node => {
        const box = node.getBoundingClientRect();
        return [node, {left: box.left - origin.left, right: box.right - origin.left,
          top: box.top - origin.top, bottom: box.bottom - origin.top, height: box.height}];
      }));
      const portY = (node, side, port) => {
        const siblings = ports.get(node)[side], box = boxes.get(node);
        return box.top + box.height / 2 + (siblings.indexOf(port) - (siblings.length - 1) / 2) * 14;
      };
      ports.forEach(sides => Object.values(sides).forEach(siblings => siblings.sort((a, b) =>
        boxes.get(a.other).top - boxes.get(b.other).top)));
      const namespace = 'http://www.w3.org/2000/svg';
      svg.setAttribute('viewBox', `0 0 ${board.offsetWidth} ${board.offsetHeight}`);
      const marker = document.createElementNS(namespace, 'marker');
      marker.setAttribute('id', 'flow-arrow');
      marker.setAttribute('viewBox', '0 0 10 10'); marker.setAttribute('refX', '10');
      marker.setAttribute('refY', '5'); marker.setAttribute('markerWidth', '12');
      marker.setAttribute('markerHeight', '12'); marker.setAttribute('markerUnits', 'userSpaceOnUse');
      marker.setAttribute('orient', 'auto-start-reverse');
      const arrow = document.createElementNS(namespace, 'path');
      arrow.setAttribute('d', 'M 0 0 L 10 5 L 0 10 z'); arrow.setAttribute('fill', '#9bb7cd');
      marker.append(arrow); const defs = document.createElementNS(namespace, 'defs'); defs.append(marker); svg.append(defs);
      const paths = [];
      routes.forEach(route => {
        const {edge, source, target, sourceStage, targetStage, sourceSide, targetSide, sameStage} = route;
        const a = boxes.get(source), b = boxes.get(target);
        const y1 = portY(source, sourceSide, route.sourcePort), y2 = portY(target, targetSide, route.targetPort);
        const x1 = a[sourceSide], x2 = b[targetSide];
        const start = [x1, y1], end = [x2, y2];
        let d = `M ${start.join(' ')} `;
        if (sameStage) {
          const reach = (20 + route.arcIndex * 18) / .75, dy = y2 - y1;
          d += cubic(start, [x1 + reach, y1 + dy * .2], [x2 + reach, y2 - dy * .2], end);
        } else {
          // Travel directly to the destination. Cards are opaque and paint
          // above the SVG, so intermediate cards cover the crossing wire.
          const [controlA, controlB] = gentleControls(start, end);
          d += cubic(start, controlA, controlB, end);
        }
        const group = document.createElementNS(namespace, 'g'); group.classList.add('flow-wire');
        const halo = document.createElementNS(namespace, 'path'); halo.classList.add('flow-wire-halo'); halo.setAttribute('d', d);
        const path = document.createElementNS(namespace, 'path');
        path.classList.add('flow-path'); path.setAttribute('marker-end', 'url(#flow-arrow)');
        path.dataset.flowSource = edge.dataset.flowSource;
        path.dataset.flowTarget = edge.dataset.flowTarget;
        path.setAttribute('d', d);
        group.append(halo, path); svg.append(group); paths.push({path, group, source, target});
      });
      const highlight = selected => {
        nodes.forEach(node => node.classList.remove('related'));
        paths.forEach(({path, group, source, target}) => {
          const active = source === selected || target === selected;
          path.classList.toggle('active', active); group.classList.toggle('active', active);
          if (active) svg.append(group);
          if (active) { source.classList.add('related'); target.classList.add('related'); }
        });
      };
      nodes.forEach(node => {
        node.removeAttribute('title'); // The reserved preview contains the full name.
        const show = () => { dismissedFlowId = ''; highlight(node); showInspector(node); };
        node.onmouseenter = show;
        node.onmouseleave = null;
        node.onblur = null;
        node.onfocus = show;
      });
      board.closest('.flow-workspace').querySelector('.flow-preview-close').onclick = clearPreview;
      const selected = [...nodes.values()].find(node => node === document.activeElement || node.matches(':hover'))
        || nodes.get(selectedFlowId);
      if (selected && selected.dataset.flowNode !== dismissedFlowId) {
        highlight(selected); showInspector(selected);
      } else {
        clearPreview();
      }
    });
  };
  drawFlow();
  document.addEventListener('htmx:after:swap', () => {
    // Morphing option attributes can leave the select's live value at its first
    // option. Restore the server's accepted focus, including on same-focus updates.
    const view = document.getElementById('flow-view');
    if (view) {
      view.querySelector('select[name="focus"]').value = view.dataset.flowFocus;
      view.querySelector('input[name="internal"]').checked = view.dataset.flowInternal === '1';
    }
    requestAnimationFrame(drawFlow);
  });
  window.addEventListener('resize', drawFlow);
  document.fonts?.ready.then(drawFlow);
  const url = document.body.dataset.liveUrl;
  if (!url) return;
  const stream = new EventSource(url);
  const label = document.getElementById('connection-state');
  let pending = false;
  let scheduled = false;
  const editing = () => document.activeElement?.matches('input, textarea, select');
  const refresh = () => {
    if (editing()) { pending = true; return; }
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => {
      scheduled = false;
      pending = false;
      document.body.dispatchEvent(new CustomEvent('redsourcing:update', { bubbles: true }));
    }, 120);
  };
  stream.addEventListener('open', () => {
    if (label) label.textContent = 'Live';
    document.body.classList.remove('disconnected');
    refresh(); // Reconnect always reloads authoritative state; signals need no replay.
  });
  stream.addEventListener('refresh', refresh);
  stream.addEventListener('error', () => {
    if (label) label.textContent = 'Reconnecting';
    document.body.classList.add('disconnected');
  });
  document.addEventListener('focusout', () => { if (pending) setTimeout(refresh, 0); });
  document.addEventListener('htmx:after:request', event => {
    const form = event.target.closest?.('form');
    if (form?.matches('#operation-form, .entity-operation-form')) {
      const button = form.querySelector('button[type="submit"]');
      if (button) button.disabled = false;
    }
    if (!form || !event.detail.ctx?.response?.raw?.ok) return;
    if (form.dataset.reset === 'true') form.reset();
    if (!form.matches('.entity-operation-form')) form.closest('details')?.removeAttribute('open');
    document.activeElement?.blur();
    refresh();
  });
  document.addEventListener('htmx:before:request', event => {
    const form = event.target.closest?.('form');
    if (form?.matches('#operation-form, .entity-operation-form')) {
      const button = form.querySelector('button[type="submit"]');
      if (button) button.disabled = true;
    }
  });
  window.addEventListener('pagehide', () => stream.close(), { once: true });
})();
