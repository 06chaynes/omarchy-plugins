# Omagotchi — Roadmap & design de référence

Document de travail (fr). Les chiffres « actuels » sont extraits du code au
2026-08-20. Deadline concours : **lundi 24/08, 9h CEST**.

---

## 1. Stades d'évolution — état actuel

L'âge compte les **minutes de shell actif** (machine éteinte = pause).
Le « soin » = moyenne du bonheur échantillonné chaque minute, **remis à zéro à
chaque évolution**.

| Stade | Forme(s) | Évolue à (âge total) | Durée du stade | Condition de branche |
| --- | --- | --- | --- | --- |
| Œuf | `egg` | 5 min | 5 min | — |
| Bébé | `baby` | 70 min | 65 min | — |
| Enfant | `child` | 550 min | 480 min (8 h) | soin ≥ 55 → ado propre, sinon ado crado |
| Ado | `teen_neat` / `teen_scruffy` | 1510 min | 960 min (16 h) | voir tableau adultes |
| Adulte | `adult_ace` / `adult_ok` / `adult_gremlin` | — | ∞ | — |

Branches adulte (hommage au chart Gen1 : l'ado crado plafonne un cran plus bas) :

| Soin moyen de l'ado | Depuis ado propre | Depuis ado crado |
| --- | --- | --- |
| ≥ 75 | `adult_ace` | `adult_ok` |
| ≥ 40 | `adult_ok` | `adult_gremlin` |
| < 40 | `adult_gremlin` | `adult_gremlin` |

**Décision (2026-08-20)** : l'arbre est figé à 2 ados / 3 adultes — suffisant.
L'arbre Gen1 complet est abandonné (le chart reste une référence d'ambiance).

**Départ & générations** : à l'âge adulte, un bouton « Let it go » (avec
confirmation) permet de laisser partir son compagnon — clin d'œil au
Tamagotchi original qui repartait sur sa planète. Un nouvel œuf apparaît et
le **compteur de générations** s'incrémente (« Gen 2 », « Gen 3 »… affiché
dans le panel).

---

## 2. Besoins — état actuel

Tous montent de 0 (bien) à 100 (critique) par tick de minute active. Le pet
se plaint (humeur + gigote dans la barre) à partir de **60**.

| Besoin | Vitesse de base | 0 → 100 | Modulateurs | Se soigne par |
| --- | --- | --- | --- | --- |
| Faim | +0,33/min | ~5 h 03 | updates en attente → +0,5/min ; ×stade (§3) | bouton Feed (à la maison uniquement) |
| Hygiène | +0,21/min | ~7 h 56 | orphelins pacman → +0,33/min ; ×stade | **frotter à la souris** dans sa chambre (0,03 pt/px, gigote + étincelles) |
| Énergie (fatigue) | +0,28/min éveillé | ~6 h (s'endort à 90) | balade → +0,55/min ; ×stade | sieste auto : −2,2/min, réveil à ≤ 5 (~39 min) ; s'endort dès 60 quand on le fait rentrer ; nourrir/laver le réveille puis il se rendort si encore fatigué |
| Fun (ennui) | +0,45/min | ~3 h 42 | balade → **−2/min** ; ×stade | sortir se balader (caresse : −10) |
| Affection | +0,12/min | ~14 h actives | chute sonnée → **+10** (l'anti-câlin) | **session de câlins** : −10 par caresse |

Bulles d'emote : si plusieurs besoins ≥ 60, la bulle alterne toutes les 3 s.
Stun : 3 étoiles (`emote_stunned.png`) en orbite code, pas de bulle.

## 3. Besoins — ajustements par stade (À VALIDER ensemble)

Idée : un multiplicateur par stade et par besoin. Proposition de départ :

| Stade | Faim | Fatigue | Ennui | Comportement |
| --- | --- | --- | --- | --- |
| Bébé | ×1,5 (~3 h 20) | **×2** (sieste ~toutes les 2 h 40) | ×0,5 (pas de balade de toute façon) | dort tout le temps, mange souvent |
| Enfant | ×1 | ×1 | **×1,5** (~2 h 30) | déborde d'énergie, veut sortir |
| Ado | **×2** (~2 h 30) | ×0,8 | **×0,5** (~7 h 20) | dévore le frigo, casanier |
| Adulte | ×1 | ×1 | ×1 | référence |

- **Ado + panel** : quand l'ado est dans son panel (pas en balade), il sort un
  petit laptop (sprite simplifié, 2 frames) au lieu de l'idle classique.
- Question ouverte : l'ennui de l'ado devrait-il monter *plus vite* s'il ne
  touche pas à son laptop ? (gag possible, à voir)

## 4. Nouvelles mécaniques décidées

- **Sonné après une grande chute** : si la hauteur de chute dépasse un seuil
  (proposition : > 40 % de la hauteur d'écran), état `stunned` pendant
  ~3 s à l'atterrissage (sprite étoiles), insensible aux clics pendant ce temps.
- **Effets sonores (optionnels)** : petit set 8-bit (éclosion, évolution,
  miam, splash du bain, bâillement/dodo, cui-cui de caresse, « boing » de
  chute sonnée). Réglage on/off dans le panel, format WAV court dans
  `sounds/` (comme le tomato-timer). Je peux générer des bleeps chiptune
  de placeholder par script en attendant de meilleurs sons.
- **Moteur d'animations avec fallback** (côté code, prérequis à tout le
  reste) : chaque état/action tente `<form>_<anim>_*.png` et retombe sur
  l'idle de la forme si le fichier n'existe pas → les sprites peuvent être
  livrés au fil de l'eau sans jamais rien casser.
- **Bulles d'émotion partagées** (raccourci malin) : 6 petites bulles
  au-dessus de la tête (`emote_hungry`, `emote_sleepy`, `emote_dirty`,
  `emote_bored`, `emote_sad`, `emote_stun`), communes à TOUTES les formes.
  Elles rendent chaque état lisible immédiatement, même avant que les
  sprites d'état dédiés existent. À dessiner une seule fois.

---

## 5. Sprites — la liste de courses

Format : 16×16, blanc sur transparent (PNG32), nommage
`<form>_<anim>_<frame>.png`, frames `a`/`b`. Grilles texte dans
`tools/sprites/*.txt` + `tools/gen-sprites.sh`, ou export direct PNG depuis
Pixelorama — les deux marchent.

Formes : `egg`, `baby`, `child`, `teen_neat`, `teen_scruffy`, `adult_ace`,
`adult_ok`, `adult_gremlin`.

### P1 — la base redessinée (remplace mes drafts)

| Anim | Formes concernées | Frames | Total |
| --- | --- | --- | --- |
| `idle` | toutes (8) | a, b | 16 |
| `walk` | toutes sauf egg, baby (6) | a, b | 12 |
| `sleep` | toutes sauf egg (7) | a, b | 14 |

### P1,5 — les bulles partagées (gros gain, petit effort)

| Sprite | Note |
| --- | --- |
| `emote_hungry`, `emote_sleepy`, `emote_dirty`, `emote_bored`, `emote_sad`, `emote_stun` | 6 sprites uniques, taille libre (8×8 ou 16×16), affichés au-dessus de la tête |

### P2 — les animations dédiées (par ordre d'apparition à l'écran)

Priorité aux formes qu'on voit longtemps : `child`, les 2 `teen_*`, puis les
3 adultes. (Bébé passe vite, œuf n'a besoin de rien.)

| Anim | Usage | Frames |
| --- | --- | --- |
| `climb` | remplace la rotation −90° actuelle | a, b |
| `eat` | pendant le Feed | a, b |
| `wash` | pendant le Clean | a, b |
| `hungry` / `dirty` / `bored` / `sad` / `sleepy` | idle d'état (si tu veux plus que la bulle) | a, b chacun |
| `stunned` | après une grande chute | a, b |
| `laptop` | **teens uniquement**, idle dans le panel | a, b |

### P2,5 — la déco de la chambre (idée de Stella 21/08)

Sprites `decor_<nom>.png` de **taille libre** (16×16 pour les petits objets,
24×24 ou 32×32 pour le poster/mobile détaillés, rectangles OK — ex. poster
16×24 portrait), affichés dans la chambre selon le stade (tamisés à 55 %, la
chambre reste meublée quand il est en balade). Un sprite non dessiné ne
s'affiche pas — livrable au fil de l'eau. `gen-sprites.sh` lit la taille de
la grille tout seul ; le zoom entier par pièce (`px`) se règle dans
`stageDecor` (Panel.qml).

| Stade | Sprites | Note |
| --- | --- | --- |
| Bébé | `decor_mobile` ✅ 32×32 (sway; **animation orbite des branches à faire**, cf. étoiles du stun) | pacifier abandonné |
| Enfant | `decor_ball` ✅ 32×32 | |
| Ado propre | `decor_poster` ✅, `decor_controller` ✅ (manette) | |
| Ado crado | `decor_poster` ✅, `decor_sock` ✅ (chaussette sale) | |
| Adulte | `decor_plant_gremlin` ✅ (cactus), `decor_plant_ok` ✅, `decor_plant_ace` ✅ (bonsaï 32×32) | déco **par forme** : `stageDecor` accepte une clé forme (`adult_ace`…) qui prime sur la clé stade |

Positions/tailles réglées dans `Panel.qml` (`stageDecor`) — faciles à ajuster.

### P3 — plus tard

- Formes supplémentaires pour l'arbre Gen1 complet + le « special ».
- Frames de chute dédiées, animation d'éclosion, contour sombre 1 px
  (lisibilité sur fonds clairs).

---

## 6. Ordre de bataille (d'ici lundi 9h)

| # | Quoi | Qui | État |
| --- | --- | --- | --- |
| 1 | Moteur d'anims avec fallback + bulles d'émotion (+ alternance) | Claude | ✅ 20/08 |
| 2 | Multiplicateurs de besoins par stade | Claude | ✅ 20/08 |
| 3 | État sonné (étoiles en orbite) + départ de l'adulte (générations) | Claude | ✅ 20/08 |
| — | Bonus 20/08 : grab & carry, session de câlins, frottage hygiène, panel (chambre vide en balade, Zzz, boutons alignés) | Claude | ✅ |
| 4 | Sons optionnels (setting + placeholders repris du tomato-timer, voir CREDITS.md) | Claude | ✅ 21/08 |
| — | Bonus 21/08 : sortie animée du panel (glisse + chute derrière la carte) + faisceau tracteur aller/retour 🛸 | Claude | ✅ |
| 5 | Sprites P1 : sleep des 7 formes + déco (mobile, ball, controller, plants, poster, sock) | **Stella** | ✅ 21/08 |
| 5b | Animation orbite du mobile (bébé) + anims `eat` (Stella) + bruitages définitifs (Stella) | ensemble | ✅ 22/08 |
| 6 | Bulles P1,5 | **Stella** | ✅ les 6 faites le 20/08 |
| 7 | Laptop de l'ado dans le panel | Claude (dès sprites teen) | ⏳ |
| 8 | Sprites P2 (eat, wash, climb, stunned, laptop, états) | **Stella** | ✅ |
| 9 | Preview.png + README final | ensemble | ⏳ |
| 10 | Repo GitHub public, `omarchy plugin validate`, scan sécurité, soumission | ensemble | ⏳ |

Règle de survie : à partir de samedi, on gèle les mécaniques et on ne fait
plus que sprites + démo + soumission.

## 7. Post-concours (backlog)

- Multi-écran (le pet suit l'écran focus ? un pet par écran ?)
- Support scale ≠ 1 (coords Hyprland vs surface)
- Se cacher quand une fenêtre passe fullscreen
- Mini-jeu de discipline ? (le chart Gen1 a une jauge discipline)
