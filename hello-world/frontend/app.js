const statusEl = document.getElementById('status');
const refreshBtn = document.getElementById('refresh');

async function loadMessage() {
  statusEl.textContent = 'Loading message…';
  try {
    const response = await fetch('/api/hello');
    if (!response.ok) {
      throw new Error(`Request failed: ${response.status}`);
    }
    const data = await response.json();
    statusEl.textContent = data.message;
  } catch (err) {
    statusEl.textContent = 'Could not load message.';
  }
}

refreshBtn.addEventListener('click', loadMessage);

loadMessage();
