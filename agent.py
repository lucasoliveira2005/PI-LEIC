import subprocess
from typing import Optional

MODEL_NAME = "llama3"
DEFAULT_TIMEOUT = 120
RETRY_TIMEOUT = 120


def _looks_like_echo(user_prompt, llm_output):
    prompt_norm = " ".join(user_prompt.strip().lower().split())
    output_norm = " ".join(llm_output.strip().lower().split())
    return output_norm == prompt_norm or output_norm in {
        f"responde: {prompt_norm}",
        f"explica: {prompt_norm}",
    }


def analyze_state(state):
    congestion = state["prb_usage"] > 80
    handover = state["sinr"] == "low"
    return congestion, handover


def run_ollama(prompt: str, timeout: int) -> str:
    try:
        result = subprocess.run(
            ["ollama", "run", MODEL_NAME],
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

        if result.returncode != 0:
            error_msg = result.stderr.strip() or "Erro desconhecido do Ollama"
            return f"Erro do LLM (exit {result.returncode}): {error_msg}"

        return result.stdout.strip() or "Sem resposta do LLM"
    except subprocess.TimeoutExpired:
        return "Timeout: LLM demorou demasiado"
    except FileNotFoundError:
        return "Erro: comando 'ollama' não encontrado. Instala o Ollama ou adiciona-o ao PATH."


def ask_llm(prompt: str) -> str:
    base_prompt = f"""
Responde sempre em português de Portugal, de forma clara e técnica quando fizer sentido.
Se o utilizador pedir para explicar um conceito, inclui:
- definição simples
- 2 a 4 pontos principais
- um exemplo prático curto

Pergunta do utilizador:
{prompt}
"""

    first_reply = run_ollama(base_prompt, timeout=DEFAULT_TIMEOUT)
    if first_reply.startswith("Erro") or first_reply.startswith("Timeout"):
        return first_reply

    if not first_reply or _looks_like_echo(prompt, first_reply):
        retry_prompt = f"""
Responde em português de Portugal e não repitas a pergunta.
Explica de forma objetiva em 6 a 10 linhas.

Pergunta:
{prompt}
"""
        retry_reply = run_ollama(retry_prompt, timeout=RETRY_TIMEOUT)
        return retry_reply or "Sem resposta do LLM"

    return first_reply


def build_network_prompt_from_user() -> Optional[str]:
    print("\nInsere os valores para análise da rede:")
    try:
        ues = int(input("UEs: ").strip())
        prb_usage = float(input("PRB usage (%): ").strip())
    except ValueError:
        print("Entrada inválida para UEs/PRB. Usa números.")
        return None
    except (EOFError, KeyboardInterrupt):
        print("\nEntrada interrompida.")
        return None

    sinr = input("SINR (low/medium/high): ").strip().lower()
    if sinr not in {"low", "medium", "high"}:
        print("SINR inválido. Usa: low, medium ou high.")
        return None

    state = {
        "ues": ues,
        "prb_usage": prb_usage,
        "sinr": sinr,
    }
    congestion, handover = analyze_state(state)

    return f"""
Estado da rede:
UEs: {state['ues']}
PRB usage: {state['prb_usage']}%
SINR: {state['sinr']}

Decisão lógica base:
- Congestionamento: {congestion}
- Handover necessário: {handover}

Explica tecnicamente esta situação, confirma se a decisão parece correta,
e sugere melhorias práticas em 3-5 pontos curtos.
"""


def print_help():
    print("\nComandos disponíveis:")
    print("/ajuda  -> mostra esta ajuda")
    print("/rede   -> pede métricas e faz análise técnica")
    print("/sair   -> termina o programa\n")

# --- main loop ---
def main():
    print("Modo interativo iniciado.")
    print("Escreve uma pergunta para o LLM.")
    print("Comandos: /ajuda, /rede (análise de rede), /sair (terminar)\n")

    while True:
        try:
            user_input = input("Tu: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nA terminar.")
            break

        if not user_input:
            continue

        if user_input.lower() in {"/sair", "sair", "exit", "quit"}:
            print("A terminar.")
            break

        if user_input.lower() in {"/ajuda", "help", "/help"}:
            print_help()
            continue

        if user_input.lower() == "/rede":
            prompt = build_network_prompt_from_user()
            if prompt is None:
                continue
        else:
            prompt = user_input

        print("\nLLM:")
        print(ask_llm(prompt))
        print()

if __name__ == "__main__":
    main()