# FS25 Living Market (Lebendiger Markt)

Script-Mod für den **Landwirtschafts-Simulator 25**. Verkaufsstellen nehmen nicht mehr unbegrenzt an: Jede Station hat pro Ware einen **Bedarf**, der beim Verkauf sinkt und sich mit der Zeit langsam wieder auffüllt. Ziel ist ein lebendiger Markt mit Nachfrage, Engpässen, Preisänderungen und Angeboten.

> Status: frühe Entwicklungsversion (0.1.0.x), noch nicht veröffentlicht.

## Funktionen

- **Begrenzter Bedarf** pro Verkaufsstelle und Ware nach Warengruppen, z. B. Getreide 250.000 l (40 % Auffüllung je Monat), Lebensmittel 30.000 l (30 %), hochwertige Endprodukte 10.000 l (20 %)
  - einstellbar in `modSettings/FS25_LivingMarket_config.xml` (wird beim ersten Start aus `config/defaultConfig.xml` angelegt)
- **Preis folgt dem Bedarf:** ab 50 % freiem Bedarf Normalpreis, darunter immer stärker fallend bis −50 % (bei 10 % und weniger)
- **Marktereignisse** (etwa 3–5 gleichzeitig, je 1–2 Monate, mit Meldung):
  - Engpass an einer Station: mehr Bedarf, Preis +10–25 %
  - Überangebot an einer Station: weniger Bedarf, Preis −10–25 %
  - marktweit gefragt oder Flaute für eine Ware (einen Monat vorher angekündigt)
  - dazu kleine Schwankungen des Bedarfs (±10 %) zu jedem Monat
- **Ausgenommen:** Produktionen, Geld/Bargeld (Bank) und Lieferungen für laufende Aufträge
- **Eigene Seite im Ingame-Menü (ESC)**
  - eine Zeile pro Ware: Lager, beste Station (höchster Preis *mit freiem Bedarf*), Preis je 1000 l, verkaufbare Menge, Erlös
  - Detailfenster mit allen Stationen der gewählten Ware: Preis, Frei / Maximum
  - Filter per Klick: Alle Waren · Lagernd · Favoriten; Suche nach Ware oder Station
  - Favoriten (Stern-Spalte), je Spieler gespeichert
- **Schimpfwortfilter des Spiels abgeschaltet** (sonst wird z. B. „Aldi“ zu „Al$i“) – Idee aus „Disable Profanity Filter“ von Supermaschine
- **Mehrsprachig:** Deutsch, Englisch, Französisch, Polnisch, Niederländisch, Spanisch, Italienisch
- **Speichert den Bedarf im Spielstand** (`livingMarket.xml` im Savegame-Ordner)
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
| `scripts/LivingMarket.lua` | Kernlogik: Bedarf, Hooks auf `SellingStation`, Lager, Preise, Menüseite einhängen |
| `scripts/LivingMarketEvents.lua` | Marktereignisse und Schwankungen |
| `scripts/gui/LivingMarketFrame.lua` | Menüseite: Warenliste, Detailfenster, Suche, Filter |
| `scripts/events/LivingMarketSyncEvent.lua` | Multiplayer-Sync Server → Clients |
| `gui/LivingMarketFrame.xml` | Layout und Profile der Menüseite |
| `config/defaultConfig.xml` | Standardwerte: Warengruppen, Maximum und Auffüllung je Monat |
| `languages/l10n_*.xml` | Texte in allen Sprachen |

## Fehlersuche

Die Mod schreibt Zeilen mit dem Präfix `[LivingMarket]` in die `log.txt` (`Dokumente/My Games/FarmingSimulator2025/`), u. a. alle Stationen mit ihren Waren beim ersten Öffnen der Seite.
