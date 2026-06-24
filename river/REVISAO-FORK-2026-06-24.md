# Revisão do fork maindeck-animations vs upstream river

**Data:** 2026-06-24
**Base de comparação:** `fork/main` (= `riverwm/river` @ `d4fef52`, v0.4.0-dev)
**Branch revisada:** `maindeck-animations` @ `791a3ab`
**Delta:** 20 arquivos, +3009 / −91 linhas

> Escopo da revisão: o que mudamos vs upstream, em código, performance,
> arquitetura e fluxo; e um veredito de PR-readiness por feature (se, caso
> quiséssemos, daria para submeter ao river upstream).

---

## 1. Mapa do que mudou (agrupado por feature, não por arquivo)

O diff parece "um trabalho de animações", mas na verdade são **5 features
independentes** empilhadas na mesma branch. Isto é o achado estrutural mais
importante: para qualquer submissão upstream, elas teriam que ser **separadas**.

| # | Feature | Arquivos | ~Linhas | Acoplamento |
|---|---------|----------|---------|-------------|
| **A** | **Engine de animação MainDeck** | `Animation.zig` (novo, 1049), `AnimationIntent.zig` (novo, 309), `Window.zig` (+488), `Output.zig` (parte), `Scene.zig` (+6), `Server.zig` (orphans), protocolo (+2 requests/2 enums) | ~2200 | Alto (é o miolo) |
| **B** | **Renderer Vulkan por padrão + isolamento glvnd/EGL** | `Server.zig` (`createRenderer`, `limitEglVendorLibraries`) | ~75 | Nenhum |
| **C** | **Tearing page-flip com backoff + logs de scanout/zero-copy** | `Output.zig` (campos `tearing_test_*`, `logDirectScanout/ZeroCopy`) | ~160 | Nenhum |
| **D** | **Otimizações de input (latência/CPU)** | `Cursor.zig` (+74), `PointerConstraint.zig`, single hit-test | ~90 | Nenhum |
| **E** | **Correções de eficiência / housekeeping** | `WindowManager.zig` (dirty lazy + hash FNV), `OutputManager.zig` (commit condicional), `LayerSurface.zig` (dedup commit), `XdgToplevel.zig`, `main.zig` (log dedup), `TextInput.zig` (err→debug), `Window.zig` (leak fix de foreign-toplevel) | ~250 | Baixo |
| **F** | **Patch de terceiros (wlroots)** | `patches/wlroots-0.20.1-cpu-cursor-compose.patch` (249) | — | Externo |

Além disso, mudanças de build (`build.zig`: xwayland default + flags Raptor Lake +
hardening) e docs (`ANIM-DECK-SWITCH-E-CLOSE.md`, `release.sh`, `.gitignore`).

---

## 2. Arquitetura da feature A (o coração)

### 2.1 A decisão central — e é uma boa decisão

O modelo é: **o WM (maindeck-wm) só manda geometria absoluta** via a render
sequence; **o compositor interpola localmente** dentro do frame loop do output.
Não há round-trip Wayland por frame de animação.

```
ação no WM ──> set_animation_intent / set_close_intent (protocolo, wire)
                 │
                 ▼
        Window.rendering_requested.{animation_intent, close_intent}
                 │  (renderFinish: decide qual armX chamar)
                 ▼
        Window.anim: ?Animation   ◄── null em repouso = custo idle ZERO
                 │
                 ▼
   Output.handleFrame ──> advanceAnimations(now_ns)  (lerp + opacity + scale/clip)
                 │            └─ Animation.advanceOrphans(now_ns)
                 ▼
   scene node setPosition/opacity ──> commit (forçado enquanto anima)
```

Pontos fortes de arquitetura:

- **Custo idle zero**: `anim: ?Animation` inline em cada `Window`; `null` em
  repouso. O loop só re-agenda frame enquanto `anim_active` (não fica girando no
  refresh à toa). Isto está alinhado com a filosofia do river.
- **Time-based, idempotente entre outputs**: `advanceAnimations(now_ns)` chamada
  de vários outputs no mesmo vblank recomputa a mesma amostra. Correto para
  multi-monitor.
- **`OrphanClose` resolve um problema real e difícil** (ver 2.2).
- **`intent` declarativo > inferência geométrica**: o histórico mostra a
  refatoração de "inferir direção pela geometria (`grew && count==1`, `box.x`
  sniffing)" para "a AÇÃO declara o intent". Isto é arquiteturalmente superior —
  o compositor não adivinha mais a intenção do WM.

### 2.2 O subsistema OrphanClose (o trecho mais inteligente)

Problema: uma janela fechada é destruída pelo compositor no próximo ciclo
manage+render após o unmap — **antes** dos 200ms da animação de close. Logo a
animação não pode viver no `Window` (os scene nodes são liberados no meio).

Solução: no `unmap`, snapshota os buffers numa **scene tree standalone**
(`close_overlay` layer, criada em `Scene.zig`), própria do subsistema, arma o
fade/slide e avança no mesmo frame loop. O orphan se autodestrói ao terminar; o
ciclo de vida do protocolo da janela real termina imediato e independente.
Buffers seguram ref no `wlr.Buffer` (mesmo mecanismo do `SaveableSurfaces` do
river). `destroyAllOrphans` no shutdown/output-destroy evita leak.

Isto é engenharia de compositor de bom nível. Tratamento de OOM em todo caminho
(`catch return` → "a janela só some, como antes").

### 2.3 Fluxo deck-switch / close (o caso mais complexo)

- **Close client-initiated** (app fecha sozinho): o WM **não consegue** reagir —
  o river desmapeia e snapshota síncrono antes do evento `closed` chegar ao WM.
  Resolvido com `set_close_intent` **sticky**: o WM pré-registra, a cada render
  onde o papel da janela (deck/main/solo) é conhecido, qual close tocar. No unmap
  o compositor sempre tem um valor fresco e explícito. (Comentário no código
  ainda descreve o método antigo de inferência geométrica no `unmap` — ver
  achado C-3.)
- **Deck-switch**: `slide_deck_out`/`_left` (saída) via orphan; `deck_in_left`/
  `_right` (entrada) na árvore viva, com **traveling clip** que fixa a borda
  esquerda na divisão main↔deck para a janela não parecer cruzar o slot principal.

---

## 3. Achados de código / performance / estilo

### 3.1 Bloqueadores para upstream (estilo river / qualidade)

- **(A-1) Instrumentação temporária `[ANIM-DIAG]` em `Window.zig`: 20 `log.info`
  ativos + 1 comentário (linha 1165).** O próprio código diz *"Remover após o
  diagnóstico das animações (2026-06-22)"*. São `log.info` em caminho quente
  (cada renderFinish). **Têm que sair** antes de qualquer submissão — e idealmente
  antes de considerar o código "final" mesmo para uso próprio. *(O log dedup em
  `main.zig`, feature E, NÃO mascara isto de forma confiável — ver E-2 — e não
  remove o custo de formatação.)*

- **(A-2) Duplicação de easing.** Há **dois** enums `Easing` e **dois**
  evaluators: `Animation.zig` usa Newton-Raphson bit-exato ao CSS
  (`cubicBezierYForX`), `AnimationIntent.zig` usa uma aproximação polinomial à
  mão (`easeProgress`, `cubic_spring`). O `AnimationIntent.easeProgress` parece
  **morto** (o dispatch real usa `animationEasingFromProtocol` → `Animation.Easing`).
  Consolidar numa fonte só.

- **(A-3) `AnimationIntent.zig` sem header SPDX.** O river exige
  `// SPDX-License-Identifier: GPL-3.0-only` em todo arquivo. `Animation.zig` tem;
  este não.

- **(A-4) Estado global mutável no módulo `Animation`:** `var orphans` +
  `var orphans_initialized` (+ `ensureOrphanList` lazy-init). O river pendura
  estado em `Server`/`Output`, não em globais de módulo. Um revisor pediria para
  mover a lista de orphans para `Server` (e o init explícito em `Server.init`).

- **(A-5) Constantes mágicas espalhadas.** Durações/deltas hardcoded nos call
  sites do `renderFinish` (ex.: `spawnDeckOut(..., 100, .ease_in)`, `0.05`,
  `0.30`, `60.0`, `0.55`) em vez de virem só da `Config` comptime de
  `AnimationIntent`. Há duas fontes de verdade para timing (a tabela `Config` e
  os literais no `Window.zig`).

### 3.2 Performance

- **(A-6) Boilerplate dos `armX`** (9 construtores, ~20 campos cada, muito
  repetidos). Não é problema de runtime (é struct literal), mas é superfície de
  manutenção e fonte de bug por divergência. Candidato a um builder/default.
- **(D, E) positivos de performance** — estas são as mudanças que *reduzem*
  custo e estão bem-feitas:
  - `Cursor.zig`: acúmulo de delta fracionário no `op` mode (corrige perda de
    micro-movimentos em mouse high-polling/low-dpi), **single hit-test** por
    motion (era múltiplo), e **dedup de `pointerNotifyMotion`** (não reenviar
    sx/sy idênticos). Correto e isolado.
  - `WindowManager.zig`: `dirtyWindowingLazy` com coalescing timer (8ms) +
    troca de hash Blake3 → FNV-1a no order-hash do render. FNV num hash de
    ordenação interno (não-cripto) é a escolha certa; Blake3 ali era exagero.
  - `OutputManager.zig`: `sendConfig`/`scheduleFrame` condicionais (só quando
    config mudou), evita trabalho redundante por commit.
  - `LayerSurface.zig`: dedup de `arrange()` quando o estado aplicado não mudou.
  - `Server.zig` (feature B): Vulkan renderer por padrão — documentado como ~10x
    menos CPU no NVIDIA (o GLES2 busy-waita no EGL context switch). Coerente com
    a memória do projeto.

### 3.3 Correção / risco

- **(E-1) Fix de leak legítimo** em `Window.destroy`: janelas destruídas antes
  do map nunca passavam por `unmap`, vazando os foreign-toplevel handles. Este é
  um bug real e o fix é correto — **inclusive é candidato a PR isolado** ao river.

- **(E-2) BUG no log dedup de `main.zig` (introduzido por nós).** O dedup
  ("last message repeated N times") considera duas mensagens iguais comparando
  `format.ptr`/`len` + scope + level — ou seja, o **template comptime**, NÃO os
  argumentos. Dois `log.info("win={s}", .{title})` com títulos diferentes têm o
  mesmo `format.ptr`, são tratados como repetição, e **só o primeiro imprime**; os
  demais somem por até 5s. Para logs com dados dinâmicos (coordenadas, títulos —
  exatamente os ANIM-DIAG) isto **engole informação distinta**. É uma regressão de
  observabilidade que mascara, não corrige, o spam de A-1. Achado de auditoria
  (agy, verificado em `main.zig` no bloco `same`).

- **(A-7) BUG de mapeamento de easing.** `animationEasingFromProtocol`
  (`Window.zig`) mapeia os valores de protocolo `0x1..0x4` mas deixa `0x0`
  (linear) cair no `default`. O enum `Animation.Easing` TEM `.linear`
  (`Animation.zig:47`), então pedir linear via protocolo **nunca produz linear** —
  vira o default (ease_out/spring). Impacto prático baixo hoje (nada usa linear),
  mas é um defeito correto. Achado de auditoria (agy, verificado).
- **(F-1) O patch wlroots tem DOIS fixes**, não um: além do CPU-cursor compose,
  há um **use-after-free de heap em `wlr_drm_format_copy`** (`drm_format_set.c`:
  o `finish` deixava `modifiers` dangling → cópia posterior fazia double-free /
  corrompia modifiers). Isto é um bug do wlroots com valor upstream próprio.
- **(C-1) Risco de carona:** a lógica de tearing/scanout (feature C) vive
  embolada no `renderAndCommit`. Mexe no caminho de commit de TODO frame. Está
  guardada por `rendering_current.tearing`, mas aumenta a área de risco de um
  arquivo crítico — razão a mais para isolá-la.

---

## 4. Veredito de PR-readiness (por feature)

Pergunta: *se quiséssemos, isto poderia ir para o river upstream?* Resposta por
feature, com o que faltaria.

### A — Engine de animação MainDeck → **NÃO, como está. Reformulável.**
- **Blocker conceitual:** o river hoje **não tem** animações no core e a posição
  histórica do upstream é minimalista. Um protocolo de `animation_intent` com 16
  valores MainDeck-específicos (`fade_open`, `deck_in_left`, `grow_reveal`...)
  é **vocabulário do nosso WM**, não primitivas genéricas. O river provavelmente
  não aceitaria os intents semânticos — no máximo aceitaria primitivas
  (fade/slide/scale + curva + duração) e deixaria a *semântica* no WM.
- **Blockers técnicos:** A-1 (logs), A-2 (easing dup), A-3 (SPDX), A-4 (estado
  global), A-5 (constantes mágicas).
- **Caminho realista:** virar um **proposal de protocolo** (`set_animation` com
  primitivas neutras) + a engine de tween no compositor, sem os 16 intents de
  produto. É um RFC, não um PR pronto. Esforço alto e incerto de aceitação.
- **Para uso próprio (fork):** já funciona; limpar A-1..A-5 deixaria o fork
  saudável independente de upstream.

### B — Vulkan renderer por padrão → **Talvez, com discussão.**
- Tecnicamente limpo e isolado. Mas "trocar o renderer default" é decisão de
  projeto que o river pode preferir gating por env/opção em vez de heurística
  embutida. O isolamento glvnd (`__EGL_VENDOR_LIBRARY_FILENAMES`) é específico de
  NVIDIA/Arch (caminho hardcoded `/usr/share/glvnd/...`) — upstream pediria algo
  mais portável. **Submetível como discussão/issue**, não PR direto.

### C — Tearing backoff + logs de scanout → **Parcial.**
- O **backoff do tearing page-flip test** (parar de testar após N falhas, com
  cooldown) responde literalmente a um `TODO` que já existe no código upstream
  (*"don't try this every frame if it consistently fails"*). Esse pedaço é
  **bom candidato a PR**, isolado e bem-vindo.
- Os **logs de direct-scanout/zero-copy** são instrumentação nossa; upstream
  provavelmente não quer no nível `info`. Separar: PR do backoff, logs ficam no
  fork.

### D — Otimizações de input → **SIM, o mais submetível de tudo.**
- Acúmulo de delta fracionário, single hit-test, dedup de motion. São correções
  de qualidade genuínas, isoladas, sem dependência da feature A, e alinhadas com
  o que um compositor deve fazer. **Estes virariam PRs limpos** (1 a 3 commits).
  Recomendo, se for submeter algo, **começar por aqui**.

### E — Eficiência / housekeeping → **SIM, em PRs pequenos.**
- `Window.destroy` foreign-toplevel leak (E-1): PR de bugfix direto.
- `TextInput` err→debug: trivial, aceitável.
- `dirtyWindowingLazy`/coalescing, FNV hash, commit condicional: defensáveis como
  PRs de performance pequenos e independentes, cada um com sua justificativa.

### F — Patch wlroots → **vai para o wlroots, não para o river.**
- O **use-after-free em `wlr_drm_format_copy`** (F-1) é um PR de valor real para
  o **wlroots upstream**, independente de tudo o mais. O CPU-cursor-compose é
  mais específico do nosso caso (NVIDIA), discutível.

---

## 5. Resumo executivo

- **Qualidade de engenharia da feature A: alta.** O design (intent declarativo,
  custo idle zero, OrphanClose, tween local sem round-trip) é sólido e pensado.
  O que separa do "PR-ready" é **higiene** (logs temporários, easing duplicado,
  SPDX, estado global) e o fato de o **vocabulário ser específico do MainDeck**,
  não primitivas que o river generalizaria.
- **O maior problema não é bug — é empacotamento.** Cinco features distintas numa
  branch. Para upstream, teriam que ser desmembradas; várias delas (D, E, o
  backoff de C, os dois fixes de F) são **boas e isoladamente submetíveis hoje**.
  A feature A é a única que vira um RFC de protocolo, não um PR.
- **Ranking de submissão (se quiser contribuir de volta):**
  1. **wlroots:** use-after-free em `drm_format_copy` (F-1).
  2. **river:** otimizações de input (D) e leak de foreign-toplevel (E-1).
  3. **river:** backoff do tearing test (C, responde a TODO upstream).
  4. **river (discussão):** Vulkan default (B).
  5. **river (RFC longo):** protocolo de animação genérico (A) — sem os intents
     de produto.
- **Ações independentes de upstream (deixam o fork são):** remover os 21
  `[ANIM-DIAG]`, unificar o easing, header SPDX em `AnimationIntent.zig`, mover
  `orphans` para `Server`, e centralizar as constantes de animação na `Config`.

---

## Apêndice — referências de arquivo

| Arquivo | Papel na mudança |
|---------|------------------|
| `river/Animation.zig` | Engine de tween: `armX`, `sample`, solver bezier, `OrphanClose`, `spawnClose/DeckOut/Minimize`, `advanceOrphans` |
| `river/AnimationIntent.zig` | Enum `Intent` (16) + `Easing` (5) + tabela `Config` comptime + evaluator (duplicado) |
| `river/Window.zig` | `renderFinish` decide o armado por intent; `unmap` dispara close; campos `anim`/`anim_positioned`/`anim_focused`; handlers `set_animation_intent`/`set_close_intent`; fix de leak no `destroy` |
| `river/Output.zig` | `advanceAnimations` (driver); + feature C (tearing/scanout) |
| `river/Scene.zig` | layer `close_overlay` |
| `river/Server.zig` | Vulkan renderer + isolamento EGL; `destroyAllOrphans` no deinit |
| `river/Cursor.zig` | feature D (delta fracionário, single hit-test, dedup motion) |
| `river/WindowManager.zig` | dirty lazy + coalescing; hash FNV; global v7 |
| `river/OutputManager.zig` | commit/sendConfig condicional |
| `river/LayerSurface.zig` | dedup de arrange por estado aplicado |
| `river/XdgToplevel.zig` | clip de captura condicional; set_parent lazy |
| `river/main.zig` | log dedup ("repeated N times") |
| `river/TextInput.zig` | err→debug em 2 logs |
| `protocol/river-window-management-v1.xml` | v5→v7; +2 enums, +2 requests; **−14 linhas de doc upstream** (os exemplos A,B,C de place_above/below) |
| `patches/wlroots-...-cpu-cursor-compose.patch` | F: use-after-free em drm_format_copy + CPU cursor compose |

---

## Auditoria cruzada (2ª opinião — agy/Gemini, 2026-06-24)

Este documento foi auditado contra o código por um segundo revisor (agy), e as
afirmações factuais foram **reverificadas por mim no fonte**. Resultado:

**Correções factuais aplicadas (o auditor estava certo, verifiquei):**
- "21 logs" → **20 `log.info` + 1 comentário** (A-1).
- "−19 linhas de doc no protocolo" → **−14** (os 2 `version="5"` são bump, não
  remoção de doc; minha contagem inicial incluiu cabeçalho de diff).

**Achados novos incorporados (bugs reais que eu havia omitido, verificados):**
- **E-2** — log dedup de `main.zig` compara só o template comptime, não os args
  → silencia logs dinâmicos distintos por até 5s.
- **A-7** — `animationEasingFromProtocol` não mapeia `0x0` (linear); cai no default.

**Pontos onde DISCORDO do auditor (julgamento meu):** ele listou como "problemas"
duas coisas que são **decisões deliberadas e documentadas**, não erros:
- *Flags AVX2/`-march=native` no `wlroots_log_wrapper.c`*: ele nota que o arquivo
  só formata logs e "não justifica vetorização". Correto que o ganho ali é nulo —
  mas isto é a política de build da máquina (todas as flags `-O3 -march=native`
  em tudo, por regra do dono do fork), não um defeito de design. Inofensivo.
- *`xwayland` default `true`*: ele chama de "alteração arbitrária do upstream".
  É intencional e obrigatória para o caso de uso (jogos via Proton/XWayland); está
  no commit `791a3ab` e é o motivo de o `build.zig` ser versionado. Não é erro.

Confiança geral na auditoria: alta nos pontos factuais (todos confirmados no
código); os dois "problemas" acima são ruído de contexto (o auditor não sabia que
eram decisões do projeto). O veredito de PR-readiness (A–F) foi **concordado
integralmente** pelo segundo revisor.
