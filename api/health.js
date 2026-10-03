module.exports = function handler(req, res) {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.end(JSON.stringify({ status: 'ok', service: 'VirtualKitob', time: new Date().toISOString() }));
};