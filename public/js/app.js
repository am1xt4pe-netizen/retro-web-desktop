// Main application JavaScript - loaded on the builder's own pages
// (login, dashboard, editor, etc.) via views/layout.erb.
// The published desktop and the standalone HTML export are fully
// self-contained documents and do NOT load this file.

document.addEventListener('DOMContentLoaded', () => {
  console.log('WebDesktop Builder loaded');
});

// Desktop preview auto-refresh (used by the editor page)
function refreshPreview() {
  const iframe = document.getElementById('preview-iframe');
  if (iframe) {
    iframe.contentWindow.location.reload();
  }
}

// Draggable-icon helpers. NOTE: these aren't currently wired to any element
// automatically -- call initDraggable(el) on a `.desktop-icon` element (with
// a numeric `data-id`) if you want live drag-to-reposition outside of the
// iframe preview. The published desktop template has its own independent
// drag implementation for its window titlebars.
let draggedElement = null;
let dragOffset = { x: 0, y: 0 };

function initDraggable(element) {
  element.addEventListener('mousedown', startDrag);
  element.addEventListener('touchstart', startDrag, { passive: false });
}

function startDrag(e) {
  if (e.target.closest('.desktop-icon')) {
    draggedElement = e.target.closest('.desktop-icon');
    const rect = draggedElement.getBoundingClientRect();
    const clientX = e.touches ? e.touches[0].clientX : e.clientX;
    const clientY = e.touches ? e.touches[0].clientY : e.clientY;
    dragOffset.x = clientX - rect.left;
    dragOffset.y = clientY - rect.top;

    document.addEventListener('mousemove', doDrag);
    document.addEventListener('mouseup', stopDrag);
    document.addEventListener('touchmove', doDrag, { passive: false });
    document.addEventListener('touchend', stopDrag);
  }
}

function doDrag(e) {
  if (!draggedElement) return;
  e.preventDefault();
  const clientX = e.touches ? e.touches[0].clientX : e.clientX;
  const clientY = e.touches ? e.touches[0].clientY : e.clientY;
  const desktop = draggedElement.parentElement;
  const desktopRect = desktop.getBoundingClientRect();

  let x = clientX - desktopRect.left - dragOffset.x;
  let y = clientY - desktopRect.top - dragOffset.y;

  const gridSize = 20;
  x = Math.round(x / gridSize) * gridSize;
  y = Math.round(y / gridSize) * gridSize;

  draggedElement.style.left = x + 'px';
  draggedElement.style.top = y + 'px';
}

function stopDrag() {
  if (draggedElement) {
    const id = draggedElement.dataset.id;
    const x = parseInt(draggedElement.style.left, 10);
    const y = parseInt(draggedElement.style.top, 10);

    if (id && typeof desktopId !== 'undefined') {
      fetch(`/api/desktop/${desktopId}/item/${id}/update`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ x_position: x, y_position: y })
      });
    }
  }
  draggedElement = null;
  document.removeEventListener('mousemove', doDrag);
  document.removeEventListener('mouseup', stopDrag);
  document.removeEventListener('touchmove', doDrag);
  document.removeEventListener('touchend', stopDrag);
}

// Notification helper
function showNotification(message, type = 'info') {
  const notification = document.createElement('div');
  notification.className = `notification notification-${type}`;
  notification.textContent = message;
  notification.style.cssText = `
    position: fixed;
    top: 20px;
    right: 20px;
    padding: 12px 20px;
    background: ${type === 'success' ? '#28a745' : type === 'error' ? '#dc3545' : '#0078d7'};
    color: white;
    border-radius: 6px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.15);
    z-index: 5000;
  `;

  document.body.appendChild(notification);

  setTimeout(() => {
    notification.remove();
  }, 3000);
}

// Keyboard shortcuts
document.addEventListener('keydown', (e) => {
  if (e.ctrlKey && e.key === 's') {
    e.preventDefault();
    if (typeof saveDesktop === 'function') {
      saveDesktop();
    }
  }
});
