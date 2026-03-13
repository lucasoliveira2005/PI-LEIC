# Deliverable D1 - Desenho de Solucao

## 1. Casos de Uso

### Caso de Uso 1 - Consulta de Metricas

- Utilizador: Operador/Engenheiro de rede.
- Objetivo: Obter uma resposta em linguagem natural sobre o estado atual da rede com base nas metricas recolhidas.
- Pre-condicao: O sistema de recolha de metricas do gNB/UE esta ativo.
- Fluxo principal:
	1. O operador envia uma pergunta (ex.: "qual a latencia media da celula X nos ultimos 5 minutos?").
	2. O modulo de processamento consulta as metricas relevantes.
	3. O modulo LLM interpreta a pergunta e sintetiza a resposta.
	4. A UI/API devolve a resposta ao operador.
- Resultado esperado: Resposta clara, contextualizada e com referencia temporal.

### Caso de Uso 2 - Monitorizacao de Qualidade de Servico (QoS)

- Utilizador: Operador de rede.
- Objetivo: Ser notificado automaticamente sobre degradacao de QoS em celulas especificas.
- Pre-condicao: Limiares de alerta e regras de anomalia configurados.
- Fluxo principal:
	1. O sistema recolhe continuamente metricas (latencia, throughput, BLER, PRB, etc.).
	2. O modulo de processamento aplica regras/algoritmos de deteccao de anomalias.
	3. Quando uma condicao de alerta e detetada, e gerado um evento.
	4. A UI/API apresenta alerta e regista historico para auditoria.
- Resultado esperado: Deteccao proativa de problemas e reducao de tempo de resposta operacional.

### Caso de Uso 3 - Otimizacao de Recursos e Manipulacao da Rede

- Utilizador: Operador (com apoio do Agente AI).
- Objetivo: Permitir instrucoes em linguagem natural para sugerir ou aplicar ajustes em parametros da rede.
- Pre-condicao: Politicas de seguranca e niveis de permissao definidos.
- Fluxo principal:
	1. O operador envia uma instrucao (ex.: "reduzir potencia da celula X em 2 dB").
	2. O agente interpreta a intencao e mapeia para parametros tecnicos.
	3. O modulo de processamento valida impacto e restricoes.
	4. O sistema aplica a acao (ou apresenta sugestao para aprovacao).
	5. A UI/API devolve confirmacao e resumo da alteracao.
- Resultado esperado: Otimizacao mais rapida, com rastreabilidade e controlo humano.

## 2. Arquitetura do Sistema (Alto Nivel)

O sistema e organizado em tres camadas: Dados, Processamento e Interface. A camada de Dados integra-se com srsRAN para recolher metricas de gNB e UE em tempo quase real e publica essas metricas via ZMQ. A camada de Processamento recebe, normaliza e agrega os dados, executa deteccao de anomalias e disponibiliza inteligencia de interpretacao com apoio de um LLM para consultas e recomendacoes operacionais.

A camada de Interface disponibiliza dashboards para observabilidade, endpoints REST para integracao externa e um canal de interacao em linguagem natural com o agente. Esta separacao permite escalabilidade (processamento desacoplado da captura), manutencao mais simples e evolucao independente de cada componente.

**Diagrama de Componentes:**
![Diagrama de Componentes](diagrama-componentes.png)


## 3. Componentes Individuais (Resumo + Tecnologias)

O componente de Dados e responsavel por recolher telemetria da RAN (gNB/UE), garantir formato consistente de eventos e encaminhar as mensagens para processamento com baixa latencia. Este componente deve ser resiliente a falhas de comunicacao e suportar bufferizacao minima para nao perder eventos em picos de carga.

O componente de Processamento centraliza persistencia, normalizacao, correlacao temporal e logica analitica. E tambem neste componente que o modulo LLM transforma perguntas em consultas operacionais e gera respostas/sugestoes. A Interface expande estes resultados para o operador por dashboards, alertas e API, garantindo observabilidade e controlo de acoes.

| Componente | Funcao Principal | Tecnologias Sugeridas |
| --- | --- | --- |
| **Dados** | Captura de metricas do gNB/UE, serializacao e publicacao de eventos | Python, srsRAN, ZMQ |
| **Processamento** | Ingestao, normalizacao, armazenamento, analitica, deteccao de anomalias, apoio LLM | Python, FastAPI (servico), SQLite/PostgreSQL/InfluxDB, LLM open-source (LLaMA/GPT4All), TensorFlow/PyTorch (opcional) |
| **Interface** | Dashboards, alertas, consulta via API e interacao com operador | React.js, Grafana, FastAPI/Flask |

## 4. Interacao entre Componentes e Especificacao de Interfaces

**Diagrama de Sequencia:**
![Diagrama de Sequencia](diagrama-sequencia.png)

### 4.1 Fluxo de Interacao (alto nivel)

1. Metrics Agent envia eventos de metrica para o Processing Engine.
2. Processing Engine valida e armazena os dados.
3. AI Module consulta dados agregados e produz inferencias/recomendacoes.
4. UI/API consulta o Processing Engine para mostrar metricas, alertas e respostas ao operador.
5. Operador pode enviar comandos; o Processing Engine valida e ativa acoes no modulo de controlo da rede.

### 4.2 Interfaces entre Componentes

**Dados -> Processamento (ZMQ / JSON)**

- Dados disponibilizados:
	- `timestamp`
	- `cell_id`
	- `ue_id` (quando aplicavel)
	- `latency_ms`, `throughput_mbps`, `prb_usage_pct`, `bler_pct`, `rsrp_dbm`
	- `event_type` (metric, alarm, state)
- Dados aceites pelo Processamento:
	- Mensagens JSON com schema versionado (`schema_version`).
- Acao ativada no Processamento:
	- Ingestao, validacao de schema, escrita em base de dados e atualizacao de agregados.

**Processamento <-> AI Module (API interna / fila)**

- Dados disponibilizados pelo Processamento:
	- Series temporais agregadas por celula/UE.
	- Estado de alarmes e baseline historico.
- Dados aceites do AI Module:
	- Interpretacao de query do operador.
	- Recomendacoes de ajuste (`parameter`, `old_value`, `new_value`, `confidence`).
- Acoes ativadas:
	- Geracao de resposta natural.
	- Criacao de pedido de alteracao de configuracao.

**Processamento -> UI/API (REST/JSON)**

- Endpoints sugeridos:
	- `GET /metrics?cell_id=&from=&to=`
	- `GET /alerts?status=open`
	- `POST /query` (pergunta em linguagem natural)
	- `POST /actions` (pedido de alteracao de parametro)
- Dados disponibilizados:
	- Metricas atuais e historicas, alertas, recomendacoes, estado de execucao de acoes.
- Acoes ativadas na UI:
	- Atualizacao de dashboards, notificacoes e auditoria.

**UI/API -> Modulo de Controlo da Rede (opcional)**

- Dados aceites:
	- Comandos validados para alteracao de parametros de rede.
- Resposta esperada:
	- Confirmacao de sucesso/erro, id de transacao e timestamp.
- Acao ativada:
	- Aplicacao de configuracao no elemento de rede alvo.