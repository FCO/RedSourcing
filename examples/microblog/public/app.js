'use strict';
const $ = id => document.getElementById(id);
let users = [], active = localStorage.getItem('pio-user') || 'ana', following = [], source, cursor = null, profile = null;
const userPath = id => `/api/users/${encodeURIComponent(id)}`;
function notice(message = '') { $('notice').textContent = message; }
async function api(path, options = {}) {
  const response = await fetch(path, { ...options, headers: { 'Content-Type': 'application/json', ...options.headers } });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Não foi possível concluir a ação. Tente novamente.');
  return data;
}
function initials(id) { return (users.find(u => u.id === id)?.name || id).slice(0, 1).toUpperCase(); }
function showProfile(id) { profile = id; $('view-title').textContent = users.find(u => u.id === id)?.name || id; $('profile-heading').hidden = false; $('profile-heading').textContent = `Publicações de @${id}`; $('home').classList.remove('active'); $('my-profile').classList.toggle('active', id === active); loadFeed().catch(e => notice(e.message)); }
function renderTweets(page, append = false) {
  const existing = new Map([...$('feed').children].map(node => [node.dataset.tweetId, node]));
  const nodes = append ? [...$('feed').children] : [];
  for (const tweet of page.tweets) {
    if (existing.has(tweet.id)) {
      if (!append) nodes.push(existing.get(tweet.id));
      continue;
    }
    const item = $('tweet-template').content.firstElementChild.cloneNode(true);
    item.dataset.tweetId = tweet.id;
    item.querySelector('.avatar').textContent = initials(tweet.author);
    const author = item.querySelector('.author');
    author.textContent = users.find(u => u.id === tweet.author)?.name || tweet.author;
    author.onclick = () => showProfile(tweet.author);
    item.querySelector('.handle').textContent = `@${tweet.author}`;
    const time = item.querySelector('time');
    time.dateTime = tweet['published-at'];
    time.textContent = new Date(tweet['published-at']).toLocaleString('pt-BR', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
    item.querySelector('.tweet-text').textContent = tweet.text;
    nodes.push(item);
  }
  const current = [...$('feed').children];
  if (nodes.length !== current.length || nodes.some((node, i) => node !== current[i])) {
    $('feed').replaceChildren(...nodes);
  }
  cursor = page.next;
  $('more').hidden = cursor == null;
  $('empty').hidden = $('feed').children.length !== 0;
}
function renderPeople() {
  $('people').replaceChildren();
  for (const person of users.filter(u => u.id !== active)) {
    const row = document.createElement('div'); row.className = 'person';
    const avatar = document.createElement('div'); avatar.className = 'avatar'; avatar.textContent = initials(person.id);
    const info = document.createElement('div'); info.className = 'person-info';
    const name = document.createElement('button'); name.className = 'author'; name.textContent = person.name; name.onclick = () => showProfile(person.id);
    const handle = document.createElement('span'); handle.textContent = `@${person.id}`;
    info.append(name, handle);
    const button = document.createElement('button');
    const follows = following.includes(person.id);
    button.className = `follow${follows ? ' following' : ''}`; button.textContent = follows ? 'Seguindo' : 'Seguir';
    button.setAttribute('aria-label', `${follows ? 'Deixar de seguir' : 'Seguir'} ${person.name}`);
    button.onclick = async () => {
      button.disabled = true; notice();
      try { await api(`${userPath(active)}/following/${encodeURIComponent(person.id)}`, { method: follows ? 'DELETE' : 'POST' }); await refresh(); }
      catch (e) { notice(e.message); button.disabled = false; }
    };
    row.append(avatar, info, button); $('people').append(row);
  }
}
async function loadFeed(append = false) {
  const selected = active, viewed = profile;
  const path = profile ? `${userPath(profile)}/tweets` : `${userPath(active)}/timeline`;
  const page = await api(path + (append && cursor != null ? `?before=${cursor}` : ''));
  if (selected === active && viewed === profile) renderTweets(page, append);
}
async function refresh() {
  const selected = active;
  const state = await api(userPath(selected));
  if (selected !== active) return;
  following = state.following;
  renderPeople(); await loadFeed();
}
function subscribe() {
  source?.close(); $('connection').textContent = 'Conectando';
  const selected = active;
  source = new EventSource(`${userPath(active)}/events`);
  source.onopen = () => { $('connection').textContent = 'Ao vivo'; };
  source.onerror = () => { $('connection').textContent = 'Reconectando'; };
  source.addEventListener('timeline', event => {
    if (selected !== active) return;
    const update = JSON.parse(event.data); following = update.following; renderPeople();
    if (!profile) renderTweets(update.page);
    else loadFeed().catch(e => notice(e.message));
  });
}
async function selectUser(id) {
  active = id; localStorage.setItem('pio-user', id); $('active-user').value = id;
  $('composer-avatar').textContent = initials(id); profile = null;
  $('view-title').textContent = 'Sua timeline'; $('profile-heading').hidden = true;
  $('home').classList.add('active'); $('my-profile').classList.remove('active');
  await refresh(); subscribe();
}
async function loadUsers() {
  users = await api('/api/users'); $('active-user').replaceChildren();
  for (const user of users) { const option = document.createElement('option'); option.value = user.id; option.textContent = user.name; $('active-user').append(option); }
  if (users.length && !users.some(u => u.id === active)) active = users[0].id;
  if (users.length) await selectUser(active);
}
$('active-user').onchange = () => selectUser($('active-user').value).catch(e => notice(e.message));
$('text').oninput = () => { $('counter').textContent = `${$('text').value.length} / 280`; };
$('compose').onsubmit = async event => {
  event.preventDefault(); notice(); $('publish').disabled = true;
  try { await api(`${userPath(active)}/tweets`, { method: 'POST', body: JSON.stringify({ text: $('text').value }) }); $('text').value = ''; $('counter').textContent = '0 / 280'; await refresh(); }
  catch (e) { notice(e.message); }
  finally { $('publish').disabled = false; }
};
$('register').onsubmit = async event => {
  event.preventDefault(); notice();
  try { const id = $('user-id').value; await api('/api/users', { method: 'POST', body: JSON.stringify({ id, name: $('user-name').value }) }); active = id; await loadUsers(); $('register').reset(); }
  catch (e) { notice(e.message); }
};
$('home').onclick = () => { profile = null; $('view-title').textContent = 'Sua timeline'; $('profile-heading').hidden = true; $('home').classList.add('active'); $('my-profile').classList.remove('active'); loadFeed().catch(e => notice(e.message)); };
$('my-profile').onclick = () => showProfile(active);
$('more').onclick = () => loadFeed(true).catch(e => notice(e.message));
window.addEventListener('pagehide', () => source?.close());
loadUsers().catch(e => notice(e.message));
