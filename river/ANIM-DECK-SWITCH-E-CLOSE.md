# Deck Switch e Deck Close — lado do compositor (river)

Como o **river** executa as animações de Deck Switch (`Win+Right`/`Left`/`Tab+Tab`)
e Deck Close (`Win+Delete` / `Alt+F4`). O *gatilho* e a escolha do efeito vivem na
maindeck-wm; este doc cobre o que o compositor faz quando o intent chega (ou
quando ele precisa **inferir** o efeito).

Doc completo do lado WM (origem dos comandos):
`maindeck-wm/docs/anim-deck-switch-e-close.md`.

Arquivos relevantes aqui: `AnimationIntent.zig`, `Animation.zig`, `Window.zig`.

---

## Contrato com o WM

- Vocabulário de intents compartilhado: `AnimationIntent.zig` ↔
  `maindeck-wm/wm-animation-intents.h` (mesmos valores `0x0`..`0xb`).
- O WM envia `river_window_v1.set_animation_intent(intent, duration_ms, easing)`
  (request `since=6`). O compositor recebe em `Window.zig:829` e guarda em
  `window.rendering_requested.{animation_intent,animation_duration_ms,animation_easing}`.
- O intent é **one-shot**: aplicado no próximo `render_finish` da janela e então
  zerado (`Window.zig:1142-1144`, `:1212-1214`) para não vazar para a próxima ação.

`animationEasingFromProtocol` (`Window.zig:59`) mapeia o easing do protocolo →
`Animation.Easing` (`0x4` → `.spring`, que é `cubic-bezier(0.22,1,0.36,1)`).

---

## Motor de tween (`Animation.zig`)

Estado da animação vive inline em cada `Window` (`anim: ?Animation`); `null` em
repouso = custo zero. A interpolação roda **dentro do frame loop do output**, sem
round-trip Wayland por frame.

`Kind` (`Animation.zig:26-44`):

- `move` — interpola posição (e, opcionalmente, um size-tween).
- `slide` — glide horizontal sólido, **opacidade e escala fixas em 1.0** (nunca
  faz fade). É o contrato visual do P17 para entrada de grupo e saídas
  direcionais do deck/main.
- `open` / `close` — fade + scale pop (`armFade`).
- `nudge` — bump lateral transitório.

Armar:
- `armMove` (`:213`) — posição (+ size ratio por eixo, 1.0/1.0 = sem size tween).
- `armSlide` (`:343`) — `x → x+dx`, opacidade/escala constantes.
- `armFade` (`:293`) — fade + scale.

---

## DECK SWITCH

Recap do que chega do WM (ver doc do maindeck): o deck switch real é só
**`Win+Right` (`DECK_NEXT`)** e **`Win+Left` (`DECK_PREV`)**.

> **⚠️ `Win+Tab+Tab` NÃO é deck switch** (corrigido na auditoria 2026-06-22). O
> binding Win+Tab tem `hold_action`, então o double-tap dele dispara
> `ACTION_TOGGLE_TARGET` duas vezes (só foco), não `DECK_NEXT` — ver o doc do WM.
> Logo nada disso aqui se aplica a Win+Tab+Tab; ele não gera `SLIDE_*`.

Como o slot do deck **não muda de posição nem tamanho** (só troca qual janela o
ocupa) num `DECK_NEXT`/`DECK_PREV`, o WM manda:

- para a janela que **sai** do slot: `SLIDE_DECK_OUT`
- para a janela que **entra** no slot: `SLIDE_IN`
- para o **main**: nada (geometria idêntica)

Execução no compositor:

### `SLIDE_IN` (janela entrando) — `Window.zig:1109-1129`

No primeiro show da janela com `open_intent == .slide_in`:
- `dx = box.width * slide_in_frac`; `start_x = box.x - dx`
- `armSlide(start_x, box.y, dx, ...)` → glide de `start_x` até `box.x`
- marca `is_entrance_slide = true` para que um resize/move chegando no meio do
  glide (cliente commitando o buffer real) **não** clobbe a animação com um
  `armMove(start=target)` no-op (guard em `Window.zig:1145-1147`).

### `SLIDE_DECK_OUT` (janela saindo) — via `unmap`/orphan

Quando a janela some do layout, ela é destruída logo após o `unmap`. O slide de
saída roda numa **árvore órfã** (ver seção Deck Close abaixo): mesmo mecanismo
`spawnClose` com `CloseStyle.slide_right`.

### `SWAP`/reflow (caso 2 janelas, troca main↔deck) — `Window.zig:1145-1214`

Só arma se `moved or resized`. Position tween via `armMove` com easing `.spring`.

**Importante:** o compositor **deliberadamente NÃO escala** o buffer do cliente
durante um resize normal (`Window.zig:1156-1160`): `setDestSize` na superfície
viva corria com os commits do cliente e produzia janelas deformadas/sobrepostas
no swap. Com size ratios 1.0/1.0, `resizes()`/`scales()` são false, então
`applyScaleXY` nunca roda e a superfície mantém o auto-size nativo do river. A
re-tilagem real do tamanho vem dos `propose_dimensions` do WM, não de um scale de
textura.

> **Exceção — lone-window grow (clip reveal):** quando exatamente UMA janela
> gerenciada fica visível e ela cresceu (a última janela do deck fechou e o main
> expande para a tela toda), o compositor revela via **clip retângulo crescente**
> (não scale de textura): o conteúdo fica no tamanho final commitado (sem
> distorção) e um clip cresce da esquerda para a direita
> (`Window.zig:1162-1182`, `:1203-1205`). Ganha duração maior + `ease_out` + um
> `delay_ns` para tocar DEPOIS do fade de close.

---

## DECK CLOSE — inferência por geometria

O ponto mais sutil. Num close iniciado pelo cliente (que é o que
`river_window_v1_close` provoca), o river faz `unmap()` **sincronamente, antes**
de o evento `closed` chegar ao WM. Logo **o WM não consegue enviar um intent de
close** para a janela que sai — ele só manda reflows para as sobreviventes
(provado via harness; ver comentário em `Window.zig:1450-1461`).

Por isso o compositor **infere a direção pela geometria** em `unmap()` (bloco de
inferência `Window.zig:1462-1486`, seguido do `spawnClose` até `:1506`):

```
if anim_positioned and not fullscreen:
    others = visibleManagedCount() - 1
    inferred =
        others == 0                  -> .fade         (close solo: fade + shrink)
        window.box.x > other_x       -> .slide_right  (é o DECK, à direita)
        else                         -> .slide_left   (é o MAIN, à esquerda)
    style = match intent:
        .slide_deck_out -> .slide_right    # intent do WM, se presente, SOBREPÕE
        .slide_close    -> .slide_left
        .fade_close     -> .fade
        else            -> inferred        # caminho normal do close client-side
```

> Detalhe que evita um bug: a direção é decidida **relativa ao x da outra janela
> visível** (`minOtherVisibleX`), não contra `x > 0` — o main fica em
> `box.x + BORDER_WIDTH ≈ 3`, também `> 0`, então um threshold em 0 classificaria
> todo close de main como `slide_right` (`Window.zig:1469-1473`).

### Orphan close (`Animation.zig:575-758` — `OrphanClose` em `:594`, `spawnClose` em `:655`, `advanceOrphans` em `:729`, `destroyAllOrphans` em `:754`)

Como a janela é destruída antes do tween de ~200ms terminar, o close roda numa
árvore de cena **standalone**, fora do ciclo de vida da janela:

1. `spawnClose` cria uma `SceneTree` na layer `close_overlay` (acima das janelas
   vivas, abaixo da barra) e **copia os buffers** da janela (`copyBufferIter`);
   os scene buffers seguram ref no `wlr.Buffer`, então o snapshot sobrevive ao
   sumiço da superfície.
2. arma a animação conforme `CloseStyle`:
   - `.fade` → `armFade(.close, …, to_scale, …)` (fade 1→0 + shrink 1→`close_scale`)
   - `.slide_right` / `.slide_left` → `armSlide(x, y, ±nat_w, …)` (painel sólido)
3. `advanceOrphans` avança no frame loop e a órfã **se auto-destrói** ao terminar
   (`OrphanClose.destroy`).

O ciclo de vida real da janela no protocolo termina imediato e independente.
`destroyAllOrphans` limpa tudo em shutdown / output destroy.

---

## Defaults de timing (`Window.zig:35-55`)

- `close_anim_ms = 180` (fade de close solo; 10% mais rápido que os 200 antigos, a pedido)
- `slide_close_ms = 200` (slides direcionais)
- `close_scale = 0.65` (shrink do fade solo)
- `move_anim_ms = 280` (swap/reflow), easing `.spring`
- `open_anim_ms = 220` (fade/slide de abertura)
- `grow_reveal_ms = 240` + `grow_reveal_delay_ms = 120`, `ease_out`
- `slide_in_frac = 0.45` (offset inicial do slide-in, fração da largura)
- `nudge_px = 8` + `nudge_anim_ms = 160`

> **Inconsistência do código (não é bug, mas confunde):** `AnimationIntent.zig`
> tem uma tabela `configForIntent` (ex.: `spring` = 280ms, `reflow_ease` =
> `ease_in_out`) que **não é a fonte de verdade** para os tweens de move/swap. O
> caminho de `renderFinish` (`Window.zig:1186-1187`) usa constantes **hardcoded**
> (`move_anim_ms`, easing `.spring`) e ignora a duração/easing que o WM mandou
> para `REFLOW_EASE`/`SPRING`. O `rendering_requested.animation_*` do WM só é
> efetivamente consumido nos caminhos de **open** (`:1117`) e **close**
> (`:1489-1495`). Ou seja: para deck-switch via swap, quem manda é a constante do
> compositor, não o intent do WM.

---

## Tabela-resumo (execução)

| Comando      | Intent que chega         | Como o river executa                                  |
|--------------|--------------------------|-------------------------------------------------------|
| Win+Right    | `SLIDE_IN`+`SLIDE_DECK_OUT` | entra: `armSlide` live; sai: orphan `slide_right`   |
| Win+Left     | `SLIDE_IN`+`SLIDE_DECK_OUT` | idem, direção espelhada                             |
| Win+Tab (hold) | `SPRING`               | `armMove` easing `.spring` (2 janelas trocam de slot/tamanho) |
| Win+Tab+Tab  | — (só foco)              | **NÃO gera animação de deck** (TOGGLE_TARGET ×2)      |
| Deck Close   | (nenhum — inferido)      | `unmap` infere por geometria → orphan `slide_right`/`slide_left`/`fade` |
