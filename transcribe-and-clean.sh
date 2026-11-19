#!/usr/bin/env bash
set -euo pipefail

# Um script para todos os atalhos:
# record2.sh /caminho/para/prompt.txt

DIR="$HOME/Gravacoes"
STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ditado"
WHISPER_URL="http://127.0.0.1:9000/v1/audio/transcriptions"
OLLAMA_URL="http://127.0.0.1:11434/api/generate"
OLLAMA_MODEL="gemma4:e2b"

mkdir -p "$DIR" "$STATE_DIR"
PIDFILE="$STATE_DIR/recorder.pid"
FILESTATE="$STATE_DIR/audio.path"
PROMPTSTATE="$STATE_DIR/prompt.path"
LOGFILE="$DIR/ditado.log"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE"
}

notificar() {
    notify-send -a "Ditado por voz" -t 3000 "$1" "$2" || true
}

erro() {
    log "ERRO: $1"
    notificar "Erro no ditado" "$1"
    printf 'Erro: %s\n' "$1" >&2
    exit 1
}

if [[ $# -ne 1 ]]; then
    erro "Uso: record2.sh CAMINHO_DO_PROMPT"
fi

# Evita dois acionamentos simultâneos. O gravador NÃO herda esse lock.
exec 9>"$STATE_DIR/lock"
flock -n 9 || exit 0

# ============================================================
# SEGUNDO ACIONAMENTO: parar, transcrever e revisar
# ============================================================
if [[ -f "$PIDFILE" && -f "$FILESTATE" ]]; then
    PID="$(cat "$PIDFILE")"
    ARQUIVO="$(cat "$FILESTATE")"

    if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then
        PROCESSO="$(ps -p "$PID" -o comm= | xargs)"
        [[ "$PROCESSO" == "pw-record" ]] || erro "PID não pertence ao pw-record."

        [[ -f "$PROMPTSTATE" ]] || erro "Prompt da gravação não encontrado."
        PROMPT_FILE="$(cat "$PROMPTSTATE")"

        log "GRAVAÇÃO: encerrando PID=$PID"
        notificar "Gravação encerrada" "Finalizando arquivo de áudio..."
        kill -INT "$PID"

        for ((i=0; i<100; i++)); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$PID" 2>/dev/null; then
            erro "O pw-record não encerrou em 10 segundos."
        fi
        [[ -s "$ARQUIVO" ]] || erro "Arquivo de áudio vazio."

        rm -f "$PIDFILE" "$FILESTATE" "$PROMPTSTATE"
        flock -u 9  # Permite outra gravação durante o processamento.

        [[ -f "$PROMPT_FILE" && -r "$PROMPT_FILE" ]] || erro "Prompt não disponível: $PROMPT_FILE"
        PROMPT="$(cat "$PROMPT_FILE")"
        [[ -n "${PROMPT//[[:space:]]/}" ]] || erro "Arquivo de prompt vazio."
        BASE="${ARQUIVO%.wav}"

        # -------------------- WHISPER ------------------------
        log "WHISPER: iniciando"
        notificar "Whisper iniciado" "Transcrevendo o áudio..."
        if ! RESPOSTA_WHISPER="$(
            curl -fsS --connect-timeout 5 --max-time 180 \
                "$WHISPER_URL" \
                -F "file=@${ARQUIVO};type=audio/wav" \
                2>> "$LOGFILE"
        )"; then
            erro "Falha na transcrição com Whisper."
        fi
        if ! ORIGINAL="$(jq -er '.text | select(type == "string")' <<< "$RESPOSTA_WHISPER")"; then
            erro "Whisper retornou resposta inválida."
        fi
        [[ -n "${ORIGINAL//[[:space:]]/}" ]] || erro "Transcrição vazia."
        printf '%s\n' "$ORIGINAL" > "${BASE}.original.txt"
        log "WHISPER: concluído (${#ORIGINAL} caracteres)"

        # -------------------- GEMMA --------------------------
        PALAVRAS="$(wc -w <<< "$ORIGINAL")"
        MAX_TOKENS=$((PALAVRAS * 4 + 128))
        if (( MAX_TOKENS < 256 )); then MAX_TOKENS=256; fi
        if (( MAX_TOKENS > 4096 )); then MAX_TOKENS=4096; fi

        PAYLOAD="$(jq -n \
            --arg model "$OLLAMA_MODEL" \
            --arg system "$PROMPT" \
            --arg prompt "$ORIGINAL" \
            --argjson max_tokens "$MAX_TOKENS" \
            '{
                model: $model,
                system: $system,
                prompt: $prompt,
                stream: false,
                think: false,
                keep_alive: -1,
                options: {
                    temperature: 0.2,
                    num_predict: $max_tokens,
                    num_ctx: 4096
                }
            }')"

        log "GEMMA: iniciando modelo=$OLLAMA_MODEL; prompt=$PROMPT_FILE"
        notificar "Gemma 4 iniciado" "Revisando com $(basename "$PROMPT_FILE")..."

        if RESPOSTA_GEMMA="$(
            curl -fsS --connect-timeout 5 --max-time 90 \
                "$OLLAMA_URL" \
                -H 'Content-Type: application/json' \
                -d "$PAYLOAD" \
                2>> "$LOGFILE"
        )"; then
            printf '%s\n' "$RESPOSTA_GEMMA" > "${BASE}.ollama.json"
            log "GEMMA: resposta recebida"
            jq -r '"GEMMA: tokens=\(.eval_count // 0), total=\((.total_duration // 0) / 1000000000)s"' \
                <<< "$RESPOSTA_GEMMA" >> "$LOGFILE" || true

            # O texto está diretamente no JSON da API, sem fromjson.
            if CORRIGIDO="$(jq -er '.response | select(type == "string" and length > 0)' <<< "$RESPOSTA_GEMMA")"; then
                printf '%s\n' "$CORRIGIDO" > "${BASE}.txt"
                printf '%s' "$CORRIGIDO" | wl-copy
                log "GEMMA: concluído (${#CORRIGIDO} caracteres)"
                notificar "Texto pronto!" "Gemma concluiu a revisão. Use Ctrl+V."
                exit 0
            fi
            log "ERRO: resposta do Gemma sem texto válido."
        else
            log "ERRO: Ollama falhou ou excedeu o tempo limite."
        fi

        # Fallback: nunca perde a transcrição do Whisper.
        printf '%s\n' "$ORIGINAL" > "${BASE}.txt"
        printf '%s' "$ORIGINAL" | wl-copy
        log "FALLBACK: texto original do Whisper copiado."
        notificar "Falha na revisão com Gemma" "Original copiado. Consulte ditado.log."
        exit 0
    fi

    log "GRAVAÇÃO: removendo estado antigo."
    rm -f "$PIDFILE" "$FILESTATE" "$PROMPTSTATE"
fi

# ============================================================
# PRIMEIRO ACIONAMENTO: escolher prompt e iniciar gravação
# ============================================================
PROMPT_FILE="$1"
[[ -f "$PROMPT_FILE" && -r "$PROMPT_FILE" ]] || erro "Arquivo de prompt não encontrado: $PROMPT_FILE"
PROMPT_FILE="$(realpath "$PROMPT_FILE")"
[[ -s "$PROMPT_FILE" ]] || erro "Arquivo de prompt vazio."

ARQUIVO="$DIR/audio-$(date +%Y%m%d-%H%M%S)-$$.wav"
pw-record "$ARQUIVO" 9>&- &
PID=$!
sleep 0.2
kill -0 "$PID" 2>/dev/null || erro "Não foi possível iniciar o pw-record."

printf '%s\n' "$PID" > "$PIDFILE"
printf '%s\n' "$ARQUIVO" > "$FILESTATE"
printf '%s\n' "$PROMPT_FILE" > "$PROMPTSTATE"
log "GRAVAÇÃO: iniciada PID=$PID; prompt=$PROMPT_FILE"
notificar "Gravando áudio" "Modo: $(basename "$PROMPT_FILE"). Pressione novamente para finalizar."
