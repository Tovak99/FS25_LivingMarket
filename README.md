# FS25 Living Market (Lebendiger Markt)

Script-Mod für den **Landwirtschafts-Simulator 25**. Verkaufsstellen nehmen nicht mehr unbegrenzt an: Jede Station hat pro Ware einen **Bedarf**, der beim Verkauf sinkt und sich mit der Zeit langsam wieder auffüllt. Ziel ist ein lebendiger Markt mit Nachfrage, Engpässen, Preisänderungen und Angeboten.

> Status: frühe Entwicklungsversion (0.1.0.x), noch nicht veröffentlicht.

## Funktionen

- **Begrenzter Bedarf** pro Verkaufsstelle und Ware, Auffüllen jede Spielstunde
- **Ausgenommen:** Produktionen, Geld/Bargeld (Bank) und Lieferungen für laufende Aufträge
- **Eigene Seite im Ingame-Menü (ESC)**
  - eine Zeile pro Ware: Lager, beste Station (höchster Preis *mit freiem Bedarf*), Preis je 1000 l, verkaufbare Menge, Erlös
  - Detailfenster mit allen Stationen der gewählten Ware: Art, Preis, Frei / Maximum
  - Filter „Nur Lagerbestand“ und Suche nach Ware oder Station
- **Einzelhandel / Großhandel:** Einzelhandel nimmt nie Schüttgut (Waren ohne Palette)
- **Mehrsprachig:** Deutsch, Englisch, Französisch, Polnisch, Niederländisch, Spanisch, Italienisch
- **Multiplayer-fähig aufgebaut:** Der Server verwaltet den Bedarf und synchronisiert ihn (noch ungetestet)

## Installation

1. Den Inhalt dieses Repositorys als Zip packen, sodass `modDesc.xml` direkt im Zip liegt (nicht in einem Unterordner).
2. Die Zip **`FS25_LivingMarket.zip`** nennen und in den Mods-Ordner legen:
   `Dokumente/My Games/FarmingSimulator2025/mods/`
3. Beim Laden des Spielstands die Mod in der Mod-Auswahl aktivieren.

## Aufbau

| Datei | Inhalt |
|---|---|
| `modDesc.xml` | Mod-Beschreibung, Version, Skripte, Sprachen |
| `scripts/LivingMarket.lua` | Kernlogik: Bedarf, Hooks auf `SellingStation`, Lager, Kategorien, Menüseite einhängen |
| `scripts/gui/LivingMarketFrame.lua` | Menüseite: Warenliste, Detailfenster, Suche, Filter |
| `scripts/events/LivingMarketSyncEvent.lua` | Multiplayer-Sync Server → Clients |
| `gui/LivingMarketFrame.xml` | Layout und Profile der Menüseite |
| `languages/l10n_*.xml` | Texte in allen Sprachen |

## Fehlersuche

Die Mod schreibt Zeilen mit dem Präfix `[LivingMarket]` in die `log.txt` (`Dokumente/My Games/FarmingSimulator2025/`), u. a. alle Stationen mit Kategorie und Waren beim ersten Öffnen der Seite.
