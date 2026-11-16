import 'package:beacon/core/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

// The web's alert wording (beacon-web en, fr and sv catalogs). The app uses the
// same kind names, descriptions and state words so the two never drift.
const kinds = [
  'gone_quiet',
  'back_online',
  'battery_low',
  'battery_falling',
  'rebooted',
  'temperature',
  'noise_high',
  'clock',
  'observer_offline',
];

const names = {
  'en': [
    'Gone quiet',
    'Back online',
    'Battery low',
    'Battery falling',
    'Rebooted',
    'Temperature',
    'Noise high',
    'Clock drift',
    'Observer offline',
  ],
  'fr': [
    'Silence',
    'De retour',
    'Batterie faible',
    'Batterie en baisse',
    'Redémarrage',
    'Température',
    'Bruit élevé',
    "Dérive d'horloge",
    'Observateur hors ligne',
  ],
  'sv': [
    'Tystnat',
    'Tillbaka online',
    'Lågt batteri',
    'Fallande batteri',
    'Startade om',
    'Temperatur',
    'Högt brus',
    'Klockavvikelse',
    'Observatör offline',
  ],
};

const whens = {
  'en': [
    'When the radio has not been heard for this long.',
    'When the radio is heard again after it went quiet.',
    'When the battery stays below this voltage.',
    'When the battery drops faster than this in a day.',
    'When the radio restarts.',
    'When the temperature goes below the low limit or above the high limit.',
    'When the noise floor stays above this level.',
    "When the radio's clock is off by more than this.",
    'When the observer sends no status report for this long.',
  ],
  'fr': [
    "Quand la radio n'a pas été entendue depuis ce délai.",
    'Quand la radio est de nouveau entendue après un silence.',
    'Quand la batterie reste sous cette tension.',
    'Quand la batterie baisse plus vite que cela en une journée.',
    'Quand la radio redémarre.',
    'Quand la température passe sous la limite basse ou au-dessus de la limite haute.',
    'Quand le niveau de bruit reste au-dessus de cette valeur.',
    "Quand l'horloge de la radio s'écarte de plus que cela.",
    "Quand l'observateur n'envoie aucun rapport d'état depuis ce délai.",
  ],
  'sv': [
    'När radion inte har hörts på så här länge.',
    'När radion hörs igen efter att ha tystnat.',
    'När batteriet stannar under den här spänningen.',
    'När batteriet sjunker snabbare än så här på ett dygn.',
    'När radion startar om.',
    'När temperaturen går under den låga gränsen eller över den höga.',
    'När brusnivån stannar över den här nivån.',
    'När radions klocka avviker mer än så här.',
    'När observatören inte skickar någon statusrapport på så här länge.',
  ],
};

const states = {
  'en': ['OK', 'Alerting since X', 'No data right now', 'Not checked yet'],
  'fr': [
    'OK',
    'En alerte depuis X',
    'Aucune donnée pour le moment',
    'Pas encore vérifié',
  ],
  'sv': ['OK', 'Larmar sedan X', 'Inga data just nu', 'Inte kontrollerad än'],
};

const others = {
  'en': {
    'alerts.empty':
        'Alerts are set on radios in your Atlas. Add a radio there first.',
    'alerts.requestAttention': 'You are always told when one of your telemetry requests needs attention.',
    'alerts.needsGoneQuiet': 'Turn on {{name}} first.',
    'alerts.voltsPerDay': '{{volts}} V per day',
    'alerts.input.minutes': 'No report for',
    'alerts.input.low': 'Low ({{symbol}})',
    'alerts.input.high': 'High ({{symbol}})',
  },
  'fr': {
    'alerts.empty': "Les alertes se règlent sur les radios de votre Atlas. Ajoutez d'abord une radio.",
    'alerts.requestAttention': "Vous êtes toujours prévenu quand une de vos demandes de télémétrie demande votre attention.",
    'alerts.needsGoneQuiet': 'Activez d\'abord « {{name}} ».',
    'alerts.voltsPerDay': '{{volts}} V par jour',
    'alerts.input.minutes': 'Sans rapport depuis',
    'alerts.input.low': 'Bas ({{symbol}})',
    'alerts.input.high': 'Haut ({{symbol}})',
  },
  'sv': {
    'alerts.empty': 'Aviseringar ställs in på radioapparater i din Atlas. Lägg först till en radio.',
    'alerts.requestAttention': 'Du får alltid besked när en av dina telemetribegäranden behöver uppmärksamhet.',
    'alerts.needsGoneQuiet': 'Slå först på {{name}}.',
    'alerts.voltsPerDay': '{{volts}} V per dygn',
    'alerts.input.minutes': 'Ingen rapport på',
    'alerts.input.low': 'Låg ({{symbol}})',
    'alerts.input.high': 'Hög ({{symbol}})',
  },
};

void main() {
  setUp(loadAssets);
  tearDown(() => language = 'en');

  for (final lang in ['en', 'fr', 'sv']) {
    test('$lang kind names, descriptions and states match the web', () {
      language = lang;
      for (var i = 0; i < kinds.length; i++) {
        expect(
          trKey('alerts.kind.${kinds[i]}'),
          names[lang]![i],
          reason: kinds[i],
        );
        expect(
          trKey('alerts.when.${kinds[i]}'),
          whens[lang]![i],
          reason: kinds[i],
        );
      }
      final got = [
        trKey('alerts.state.ok'),
        trKey('alerts.state.firing').replaceAll('{{when}}', 'X'),
        trKey('alerts.state.inactive'),
        trKey('alerts.state.unknown'),
      ];
      expect(got, states[lang]);
      others[lang]!.forEach(
        (key, text) => expect(trKey(key), text, reason: key),
      );
    });
  }

  test('durations read as words in every language', () {
    for (final lang in ['en', 'fr', 'sv']) {
      language = lang;
      for (final unit in ['hours', 'minutes']) {
        expect(trKey('alerts.$unit', count: 1), isNot(startsWith('alerts.')));
        expect(trKey('alerts.$unit', count: 6), contains('6'));
      }
    }
    language = 'en';
    expect(trKey('alerts.hours', count: 1), '1 hour');
    expect(trKey('alerts.hours', count: 12), '12 hours');
  });
}
