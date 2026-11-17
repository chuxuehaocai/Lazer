/* Shared by the browser frontend and the integration test. No dependencies. */
(function (root) {
  'use strict';
  class LazerClient {
    constructor(WebSocketImpl = root.WebSocket) {
      this.WebSocketImpl = WebSocketImpl;
      this.pending = new Map();
      this.serial = 0;
      this.socket = null;
    }

    async connect(address, token) {
      const url = new URL(address);
      if (url.protocol !== 'ws:' || url.hostname !== '127.0.0.1' ||
          url.pathname !== '/lazer' || url.username || url.password || url.search || url.hash) {
        throw new Error('Use the loopback WebSocket address shown by the plugin.');
      }
      this.close();
      const socket = new this.WebSocketImpl(url.href);
      this.socket = socket;
      socket.addEventListener('message', event => {
        if (this.socket !== socket) return;
        let message;
        try { message = JSON.parse(event.data); } catch { return; }
        const pending = this.pending.get(message.id);
        if (!pending) return;
        clearTimeout(pending.timer);
        this.pending.delete(message.id);
        if (message.ok === true) pending.resolve(message.result);
        else pending.reject(new Error(message.error || 'Request failed'));
      });
      socket.addEventListener('close', () => {
        if (this.socket === socket) this.close();
      });
      try {
        await new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('Connection timed out')), 5000);
          socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, {once: true});
          socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('Connection failed')); }, {once: true});
        });
        return await this.request('hello', {token});
      } catch (error) {
        this.close();
        throw error;
      }
    }

    request(method, args = {}) {
      if (!this.socket || this.socket.readyState !== 1) {
        return Promise.reject(new Error('Not connected'));
      }
      const id = ++this.serial;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new Error('Request timed out; check Lazer for a permission prompt.'));
        }, 45000);
        this.pending.set(id, {resolve, reject, timer});
        try { this.socket.send(JSON.stringify({id, method, args})); }
        catch (error) {
          clearTimeout(timer);
          this.pending.delete(id);
          reject(error);
        }
      });
    }

    close() {
      const socket = this.socket;
      this.socket = null;
      for (const pending of this.pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(new Error('Disconnected'));
      }
      this.pending.clear();
      if (socket && socket.readyState < 2) socket.close();
    }
  }
  root.LazerClient = LazerClient;
  if (typeof module !== 'undefined') module.exports = {LazerClient};
})(globalThis);
