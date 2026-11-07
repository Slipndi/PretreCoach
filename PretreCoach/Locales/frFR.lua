-- Tous les textes affichés au joueur. Le client est en français : seule locale fournie.
local _, ns = ...

ns.L = {
  PREFIX = "|cffb084ffPrêtre Coach|r",
  HELP = "Commandes : /coach probe, /coach debug",
  MINIMAP_TITLE = "Prêtre Coach",
  MINIMAP_LEFT = "Clic gauche : ouvrir le guide",
  MINIMAP_RIGHT = "Clic droit : options",
  MINIMAP_DRAG = "Glisser : déplacer le bouton",
  DEBUG_ON = "Mode debug activé.",
  DEBUG_OFF = "Mode debug désactivé.",
  PROBE_TITLE = "Prêtre Coach : sonde d'API (Ctrl+C pour copier)",
  PROBE_COMBAT_SAVED = "Relevé en combat enregistré. Retape /coach probe hors combat pour voir le résultat complet.",
  PROBE_NEED_COMBAT = "Pas encore de relevé en combat : cible un monstre, lance Mot de l'ombre : Douleur, puis retape /coach probe après le combat.",
  GUIDE_DONE = "%s : bien joué",
  GUIDE_TIER = "Nouveau palier : %s",
  GUIDE_LEVEL = "niveau %d",
  GUIDE_LEVELS = "niveaux %d-%d",
  GUIDE_RANK = "%s (rang %d)",
  GUIDE_POINTS = "%s (%d points)",
  GUIDE_NOT_LEARNED = "non apprise",
  GUIDE_UNKNOWN = "inconnu",
}
