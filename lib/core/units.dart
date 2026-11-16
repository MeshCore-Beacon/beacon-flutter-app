/// Display units. The wire is always Celsius; [unit] is the instance's 'c' or 'f'.
double toDisplayTemp(double celsius, String unit) =>
    unit == 'f' ? celsius * 9 / 5 + 32 : celsius;

double fromDisplayTemp(double value, String unit) =>
    unit == 'f' ? (value - 32) * 5 / 9 : value;

String tempSymbol(String unit) => unit == 'f' ? '°F' : '°C';

String formatTemp(double celsius, String unit, {int digits = 1}) =>
    '${toDisplayTemp(celsius, unit).toStringAsFixed(digits)} ${tempSymbol(unit)}';
