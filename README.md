# shell-ditado

Ditado por voz em português brasileiro usando **Shell Script**, **Whisper** e, opcionalmente, **Ollama** para revisão de texto.

O projeto permite gravar a fala pelo microfone, transcrevê-la localmente e copiar o resultado para a área de transferência. Com o modo de revisão, é possível selecionar um arquivo de prompt para adaptar a escrita a diferentes contextos, preservando a intenção original.

## Como funciona

```text
Microfone → pw-record → Whisper API → Texto transcrito → Área de transferência
                                            │
                                            └→ Ollama + prompt → Texto revisado
```

O objetivo é facilitar a escrita por voz, especialmente para mensagens, documentação e instruções destinadas a modelos de inteligência artificial.

## Estrutura do projeto

```text
shell-ditado/
├── prompts/
│   ├── documentacao.txt
│   ├── ia.txt
│   ├── mensagem-slack.txt
│   └── mensagem-whatsapp.txt
├── transcribe-and-clean.sh
├── transcribe.sh
├── LICENSE
└── README.md
```

| Arquivo | Finalidade |
| --- | --- |
| `transcribe.sh` | Grava áudio e obtém a transcrição do Whisper, sem revisão por LLM. |
| `transcribe-and-clean.sh` | Grava áudio, transcreve com Whisper e revisa com um modelo disponibilizado pelo Ollama. |
| `prompts/documentacao.txt` | Redação formal e documentação técnica. |
| `prompts/ia.txt` | Organização de instruções e prompts para IA. |
| `prompts/mensagem-slack.txt` | Comunicação objetiva e natural no Slack. |
| `prompts/mensagem-whatsapp.txt` | Mensagens informais, leves e com parágrafos curtos. |

## Requisitos

- Desktop **Linux** com PipeWire e `pw-record` para capturar o microfone.
- Bash, `curl`, `jq`, `flock` (util-linux) e `ps` (procps) instalados **no desktop**, onde os scripts são executados.
- `wl-copy` (`wl-clipboard`) para copiar o texto em sessões Wayland e `notify-send` para notificações.
- **Docker ou Podman** para executar os serviços Whisper e Ollama em contêineres.
- Acesso à internet na primeira execução para baixar imagens e modelos.

> **Arquitetura:** somente os servidores de IA são conteinerizados. Os scripts continuam no host para acessar o microfone, a sessão gráfica, os atalhos e a área de transferência. Não é necessário instalar Whisper, Python, Ollama ou os modelos diretamente no host.

## 1. Executar o Whisper com Docker ou Podman

O projeto usa o endpoint HTTP `POST /v1/audio/transcriptions`. A imagem [hwdsl2/whisper-server](https://hub.docker.com/r/hwdsl2/whisper-server), do mesmo mantenedor do [Whisper Transcription API Installer](https://github.com/hwdsl2/whisper-install), fornece uma implementação compatível. Consulte também o projeto [docker-whisper](https://github.com/hwdsl2/docker-whisper), atualmente associado ao [ScribeCrate](https://github.com/hwdsl2/scribecrate).

Escolha **um** dos gerenciadores de contêineres.

### Docker

```bash
# Executar apenas na máquina local, com modelos persistidos em volume.
docker run -d \
  --name shell-ditado-whisper \
  --restart unless-stopped \
  -p 127.0.0.1:9000:9000 \
  -e WHISPER_MODEL=small \
  -e WHISPER_LANGUAGE=pt \
  -e WHISPER_API_KEY= \
  -v shell-ditado-whisper-data:/var/lib/whisper \
  hwdsl2/whisper-server
```

### Podman

```bash
podman run -d \
  --name shell-ditado-whisper \
  -p 127.0.0.1:9000:9000 \
  -e WHISPER_MODEL=small \
  -e WHISPER_LANGUAGE=pt \
  -e WHISPER_API_KEY= \
  -v shell-ditado-whisper-data:/var/lib/whisper \
  docker.io/hwdsl2/whisper-server
```

O modelo `small` é um ponto de partida; modelos maiores podem melhorar a transcrição, mas consomem mais recursos. O download inicial pode demorar. Os modelos permanecem no volume mesmo que o contêiner seja recriado.

**Autenticação:** `WHISPER_API_KEY=` desabilita a exigência de chave de API para manter compatibilidade com scripts que não enviam cabeçalho `Authorization`. Use essa opção **somente em uma implantação local protegida**. Se habilitar uma chave, atualize as requisições `curl` nos scripts para enviar `Authorization: Bearer SUA_CHAVE` e mantenha a chave fora do Git.

Confira o serviço:

```bash
# Docker; troque docker por podman se necessário.
docker logs shell-ditado-whisper
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9000/docs
```

O endpoint usado pelos scripts é:

```text
http://127.0.0.1:9000/v1/audio/transcriptions
```

> O teste HTTP em `/docs` é apenas uma verificação de conectividade; para validar a transcrição de fato, envie um arquivo WAV ao endpoint com `curl -F 'file=@audio.wav'`.

## 2. Executar o Ollama com Docker ou Podman (opcional)

O [Ollama](https://github.com/ollama/ollama) é necessário apenas para `transcribe-and-clean.sh`.

### Docker

```bash
docker run -d \
  --name shell-ditado-ollama \
  --restart unless-stopped \
  -p 127.0.0.1:11434:11434 \
  -v shell-ditado-ollama-data:/root/.ollama \
  ollama/ollama

# Baixar o modelo configurado no script:
docker exec shell-ditado-ollama ollama pull gemma4:e2b
```

### Podman

```bash
podman run -d \
  --name shell-ditado-ollama \
  -p 127.0.0.1:11434:11434 \
  -v shell-ditado-ollama-data:/root/.ollama \
  docker.io/ollama/ollama

podman exec shell-ditado-ollama ollama pull gemma4:e2b
```

Confirme a disponibilidade do modelo:

```bash
curl -fsS http://127.0.0.1:11434/api/tags | jq .
```

O endpoint utilizado por `transcribe-and-clean.sh` é:

```text
http://127.0.0.1:11434/api/generate
```

O nome `gemma4:e2b` é o modelo usado no desenvolvimento. **Confira o nome configurado no script e se a tag está disponível**; você pode usar outro modelo que o Ollama ofereça.

### Aceleração por GPU (opcional)

Os comandos acima usam a configuração padrão das imagens, adequada como ponto de partida para CPU. Para NVIDIA, é necessário configurar o acesso à GPU para o gerenciador de contêineres e usar as opções apropriadas para cada imagem. No Docker, consulte a documentação de GPU do Ollama e a variante `:cuda` do Whisper; no Podman, consulte o suporte a **CDI** (`--device nvidia.com/gpu=all`). O suporte depende do driver, do toolkit NVIDIA e do hardware.

> Não é necessário executar os dois serviços na mesma rede de contêineres: os scripts Bash os acessam pelas portas publicadas no `127.0.0.1` do host.

## 3. Instalar os scripts

Clone o repositório depois de publicá-lo no GitHub:

```bash
git clone https://github.com/SEU-USUARIO/shell-ditado.git
cd shell-ditado
chmod +x transcribe.sh transcribe-and-clean.sh
```

Substitua `SEU-USUARIO` pelo proprietário real do repositório.

## 4. Utilização

### Transcrição simples

```bash
./transcribe.sh
```

Esse modo usa apenas o Whisper, sem reescrita por modelo de linguagem.

### Transcrição com revisão por IA

Passe o caminho de um prompt como argumento:

```bash
./transcribe-and-clean.sh ./prompts/mensagem-whatsapp.txt
```

Outros exemplos:

```bash
./transcribe-and-clean.sh ./prompts/mensagem-slack.txt
./transcribe-and-clean.sh ./prompts/ia.txt
./transcribe-and-clean.sh ./prompts/documentacao.txt
```

**Fluxo de acionamento:** na implementação de alternância desenvolvida para o projeto, o primeiro acionamento inicia a gravação e o segundo a encerra e processa. O prompt escolhido ao iniciar é utilizado na revisão.

> Verifique no código publicado se o modo de acionamento e os caminhos de saída correspondem a essa descrição. Esses detalhes dependem da versão efetivamente incluída no repositório.

## 5. Atalhos de teclado

Em ambientes como o GNOME, configure atalhos personalizados apontando para os scripts. Use **caminhos absolutos** nos comandos.

Exemplos, substituindo `/CAMINHO/shell-ditado` pelo diretório do projeto:

```bash
/CAMINHO/shell-ditado/transcribe-and-clean.sh /CAMINHO/shell-ditado/prompts/mensagem-whatsapp.txt
/CAMINHO/shell-ditado/transcribe-and-clean.sh /CAMINHO/shell-ditado/prompts/mensagem-slack.txt
/CAMINHO/shell-ditado/transcribe-and-clean.sh /CAMINHO/shell-ditado/prompts/ia.txt
/CAMINHO/shell-ditado/transcribe-and-clean.sh /CAMINHO/shell-ditado/prompts/documentacao.txt
```

Cada atalho utiliza o **mesmo script**, alterando apenas o arquivo de prompt.

## 6. Personalizar os prompts

Os arquivos em `prompts/` são textos simples. Você pode editá-los ou criar novos modos sem duplicar a lógica de gravação e transcrição.

Por exemplo:

```bash
cp prompts/mensagem-whatsapp.txt prompts/meu-estilo.txt
```

Depois, edite `prompts/meu-estilo.txt` e utilize-o como argumento de `transcribe-and-clean.sh`.

Os prompts devem orientar o modelo a melhorar a redação **sem resumir, omitir ou inventar informações**. Ainda assim, modelos de linguagem podem cometer erros: revise mensagens com valores, nomes, datas ou instruções importantes antes de enviá-las.

## 7. Diagnóstico

Se a gravação ou revisão não funcionar:

1. Confirme que `pw-record`, `curl`, `jq`, `wl-copy` e `notify-send` estão disponíveis **no host**.
2. Verifique se o contêiner Whisper está em execução (`docker ps` ou `podman ps`) e acessível na URL configurada.
3. Para o modo com revisão, confirme que o contêiner Ollama está ativo e que o modelo configurado foi baixado (`docker exec shell-ditado-ollama ollama list` ou equivalente com Podman).
4. Confira os logs e arquivos de saída definidos pelos scripts.
5. Teste a execução manual no terminal antes de configurar os atalhos.

## Privacidade

O fluxo pode operar localmente quando os contêineres Whisper e Ollama são executados na própria máquina. As portas dos exemplos são publicadas somente em `127.0.0.1`, sem exposição direta à rede. Caso as URLs sejam alteradas para servidores remotos, o áudio ou a transcrição poderá ser enviado a esses serviços. Verifique os endpoints antes de utilizar o sistema com conteúdo sensível.

## Projetos utilizados e agradecimentos

Este repositório é uma integração em Shell Script que utiliza APIs de projetos independentes:

- **[Ollama](https://github.com/ollama/ollama)** — execução de modelos de linguagem e disponibilização de API REST para revisão textual.
- **[Whisper Transcription API Installer](https://github.com/hwdsl2/whisper-install)** — projeto original de referência para o servidor de transcrição.
- **[docker-whisper](https://github.com/hwdsl2/docker-whisper) / [ScribeCrate](https://github.com/hwdsl2/scribecrate)** — implementação conteinerizada do servidor Whisper usada neste guia.

Agradecimentos aos mantenedores e colaboradores desses projetos. **shell-ditado não é um projeto oficial nem afiliado ao Ollama ou ao whisper-install.** Consulte os respectivos repositórios para documentação, atualizações e licenças.

## Licença

Este projeto é distribuído sob a **Licença MIT**. Consulte o arquivo [LICENSE](LICENSE) para os termos completos de uso, modificação e distribuição. As dependências e os projetos externos mantêm suas respectivas licenças.
