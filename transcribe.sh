#!/usr/bin/env bash
set -euo pipefail

DIR="$HOME/Gravacoes"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="$RUNTIME/gravacao-audio.pid"
FILESTATE="$RUNTIME/gravacao-audio.path"

WHISPER_URL="http://127.0.0.1:9000/v1/audio/transcriptions"

mkdir -p "$DIR"

# Segunda execução: finalizar gravação e transcrever
if [[ -f "$PIDFILE" ]]; then
    PID="$(cat "$PIDFILE")"

    if kill -0 "$PID" 2>/dev/null; then
        ARQUIVO="$(cat "$FILESTATE")"

        kill -INT "$PID"

        # Espera o processo terminar e liberar o WAV
        for i in {1..100}; do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done

        rm -f "$PIDFILE" "$FILESTATE"

        notify-send "Whisper" "Transcrevendo áudio..."

        # Envia o áudio ao Whisper
        if ! RESPOSTA="$(
            curl -fsS \
                --max-time 180 \
                -X POST "$WHISPER_URL" \
                -F "file=@${ARQUIVO}"
        )"; then
            notify-send "Whisper" "Erro ao enviar áudio."
            exit 1
        fi

        # Extrai o texto do JSON retornado
        if ! TRANSCRICAO="$(jq -er '.text' <<< "$RESPOSTA")"; then
            notify-send "Whisper" "Resposta sem campo text."
            exit 1
        fi

        # Copia o texto para a área de transferência
        printf '%s' "$TRANSCRICAO" | wl-copy

        notify-send "Whisper" "Transcrição copiada! Use Ctrl+V."

        exit 0
    fi

    rm -f "$PIDFILE" "$FILESTATE"
fi

ARQUIVO="$DIR/audio-$(date +%Y%m%d-%H%M%S).wav"

pw-record "$ARQUIVO" &
PID=$!

echo "$PID" > "$PIDFILE"
echo "$ARQUIVO" > "$FILESTATE"

notify-send "Gravando áudio" \
    "Pressione o atalho novamente para transcrever."
