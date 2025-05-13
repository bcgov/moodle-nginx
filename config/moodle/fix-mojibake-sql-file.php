<?php
$backup_dir = '/tmp/db-backups/';
$input = $backup_dir . 'moodle-local.2025.05.12_1641.sql';
$output = str_replace('.sql', '.fixed.sql', $input);

$mojibake_replacements = [
    'â€œ' => '“',
    'â€' => '”',
    'Ã¢â‚¬Ëœ' => "'",
    'Ã¢â‚¬â„¢' => "'",
    'â€˜' => "'",
    'â€™' => "'",
    'â€“' => '-',
    'â€”' => '-',
    'â€¦' => '…',
    'â€' => '†',
    'â€¡' => '‡',
    'â„¢' => '™',
    'Â' => '',
    'Â©' => '©',
    'Â®' => '®',
    'Â«' => '«',
    'Â»' => '»',
    'Â±' => '±',
    'Â£' => '£',
    'Â¢' => '¢',
    'Â¥' => '¥',
    'Â§' => '§',
    'Â¨' => '¨',
    'Âª' => 'ª',
    'Âº' => 'º',
    'Âœ' => 'œ',
    'Â¼' => '¼',
    'Â½' => '½',
    'Â¾' => '¾'
];

uksort($mojibake_replacements, function($a, $b) {
    return strlen($b) <=> strlen($a);
});

$in = fopen($input, 'r');
$out = fopen($output, 'w');

$buffer = '';
$line_count = 0;

while (($line = fgets($in)) !== false) {
    $buffer .= $line;
    $line_count++;
    // Look for semicolon at end of statement (not inside a string)
    if (preg_match('/;(\s*)$/', $line)) {
        // Process the full statement in $buffer
        // Use regex with 's' modifier to match across newlines
        $statement = preg_replace_callback(
            "/'((?:[^'\\\\]|\\\\.|'')*)'/s",
            function ($matches) use ($mojibake_replacements) {
                $val = $matches[1];
                $val = str_replace("''", "'", $val);
                foreach ($mojibake_replacements as $garbled => $intended) {
                    $val = str_replace($garbled, $intended, $val);
                }
                $val = preg_replace("/(?<!\\\\)'/", "''", $val);
                return "'$val'";
            },
            $buffer
        );
        fwrite($out, $statement);
        $buffer = '';
    }
}
if ($buffer !== '') {
    fwrite($out, $buffer);
}

fclose($in);
fclose($out);

echo "Done. Fixed file: $output\n";
echo "Line count: $line_count\n";
