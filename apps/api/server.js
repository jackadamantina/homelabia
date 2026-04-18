const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Chaos: aloca arrays em loop até o processo ser morto pelo OOM killer
app.post('/chaos/memory-leak', (req, res) => {
  console.error('[CHAOS] Iniciando vazamento de memória...');
  const leak = [];
  const interval = setInterval(() => {
    // Cada tick aloca ~10MB
    leak.push(Buffer.alloc(10 * 1024 * 1024));
    console.error(`[CHAOS] Heap alocado: ${Math.round(process.memoryUsage().heapUsed / 1024 / 1024)}MB`);
  }, 200);

  // Responde imediatamente para o curl não bloquear
  res.json({ status: 'memory-leak iniciado', warning: 'Pod será OOMKilled em breve' });

  // Limpa após 30s para evitar travar o processo em ambiente de teste
  setTimeout(() => clearInterval(interval), 30000);
});

// Chaos: acessa propriedade de objeto nulo, gerando TypeError (500)
app.post('/chaos/null-pointer', (req, res) => {
  console.error('[CHAOS] Disparando null pointer...');
  try {
    const obj = null;
    // TypeError intencional
    const value = obj.property.nested;
    res.json({ value });
  } catch (err) {
    console.error(`[ERROR] TypeError: ${err.message}\n${err.stack}`);
    res.status(500).json({
      error: 'Internal Server Error',
      message: err.message,
      type: 'NullReferenceException',
    });
  }
});

app.listen(PORT, () => {
  console.log(`[API] Servidor rodando na porta ${PORT}`);
});
