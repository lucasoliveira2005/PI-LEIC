# Mini guia: instalar Ollama e correr o agent.py

## 1) Instalar o Ollama (Linux)

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Confirma a instalação:

```bash
ollama --version
```

## 2) Iniciar o serviço do Ollama

Em muitas instalações, o serviço arranca automaticamente. Se não arrancar, corre:

```bash
ollama serve
```

Se usares este comando, deixa este terminal aberto.

## 3) Descarregar o modelo usado pelo script

O `agent.py` está configurado com o modelo `llama3`.

```bash
ollama pull llama3
```

## 4) (Opcional) Ativar ambiente virtual Python

Se já tens `.venv` criado no projeto:

```bash
source .venv/bin/activate
```

## 5) Executar o agente

```bash
python3 agent.py
```

## 6) Comandos dentro do agente

- `/ajuda` mostra ajuda
- `/rede` pede métricas e faz análise técnica
- `/sair` termina o programa

## Erro comum

Se aparecer `comando 'ollama' não encontrado`:

1. Reabre o terminal.
2. Confirma com `ollama --version`.
3. Se necessário, adiciona o binário ao PATH e tenta novamente.
