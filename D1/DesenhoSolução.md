# Deliverable D1 – Desenho de Solução

## 1. Casos de Uso

### Caso de Uso 1 – Consulta de Métricas

- Utilizador: Operador/engenheiro de rede

- Objetivo: Perguntar ao agente sobre métricas específicas da rede.

 - Operador faz uma pergunta → Agente lê métricas JSON → LLM interpreta → Retorna resposta em linguagem natural.

### Caso de Uso 2 – Monitorização de Qualidade de Serviço (QoS)

- Utilizador: Operador de rede

- Objetivo: Receber alertas sobre degradação da qualidade do serviço em células específicas.

- Fluxo resumido: Coleta de métricas → Processamento por parte do agente → Detecção de anomalias → Alertas/relatórios.

### Caso de Uso 3 – Otimização de Recursos e Manipulação da Rede

- Utilizador: Operador / Agente AI

- Objetivo: Permitir que o operador envie instruções em linguagem natural e o agente sugira ou aplique alterações nos parâmetros da rede.

- Fluxo resumido: Operador envia prompt → Agente interpreta instrução → Mapeia para parâmetros da célula/UE → Aplica ajustes ou envia sugestões ao módulo de controle → Operador recebe confirmação ou relatório da alteração.


## 2. Arquitetura do Sistema (Alto Nível)

O sistema é organizado em três camadas principais, que definem o fluxo global de dados e interação com o agente LLM:

A camada de **Dados** captura métricas do gNB e UE (latência, throughput, uso de recursos) usando srsRAN e envia via ZMQ (ZeroMQ) para a camada de Processamento.

A camada de **Processamento** armazena, normaliza e agrega métricas. Interpreta os dados e os prompts do utilizador.

A camada de **User Interface** mostra dashboards para visualização de métricas, API REST para consultas e eventual integração com outros sistemas, e permite interagir com o agente LLM via prompts ou comandos estruturados.

**Diagrama de Componentes:**
[COLOCAR AQUI O DIAGRAMA]
+----------------+       +----------------+       +----------------+
| Coleta de Dados| --->  | Processamento  | --->  | Interface / UI |
|  (srsRAN gNB)  |       |  e AI          |       |  Dashboards &  |
| Metrics Agent  |       |  Engine        |       |  APIs          |
+----------------+       +----------------+       +----------------+


## 3. Componentes Individuais

| Componente          | Função                                                     | Tecnologias                                     |
| ------------------- | ---------------------------------------------------------- | ----------------------------------------------- |
| **Dados**   | Capturar métricas do gNB e UE (latência, throughput, uso de recursos) e enviar para o módulo de processamento              | Python, srsRAN, ZMQ                        |
| **Processamento** | Armazenar e normalizar dados, interpretar métricas e gerar estatísticas via LLM, e sugerir ou aplicar ajustes em parâmetros da rede | SQLite, PostgreSQL/InfluxDB, Python, LLM open-source (GPT4All, LLaMA), TensorFlow/PyTorch |
| **User Interface**  | Fornecer dashboards interativos para visualização e APIs REST para consultas e prompts ao agente      | React.js, Flask/FastAPI, Grafana                |


## 4. Interação entre Componentes
**Diagrama de Sequência:**
[COLOCAR AQUI O DIAGRAMA]

Metrics Agent --> Processing Engine : envia métricas

AI Module --> Processing Engine     : envia decisões/ações
Processing Engine --> UI / API      : disponibiliza dados e alertas

UI / API --> Operador               : apresenta dashboards / alertas