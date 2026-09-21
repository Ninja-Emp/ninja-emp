<?php

declare(strict_types=1);

namespace NinjaEMP\Db\Sql;

use InvalidArgumentException;

/**
 * Rewrites named parameters (`:name`) into unique positional placeholders
 * (`$1`, `$2`, …) and builds the ordered bind array (ADR-0025 §5).
 *
 * Why: PDO named parameters cannot be reused in one statement (`:x` twice fails).
 * Rewriting to positional placeholders makes reuse legal and removes the
 * limitation, while the public API stays named.
 *
 * The scanner is quote-aware: it ignores `:name` inside single-quoted strings,
 * double-quoted identifiers, dollar-quoted strings, line comments and block
 * comments, and it never mistakes a `::` cast for a parameter.
 */
final class PlaceholderRewriter
{
    /**
     * @param array<string, mixed> $params named parameters as supplied by the caller
     *
     * @return array{sql: string, params: list<mixed>} positional SQL + ordered bind values
     */
    public function rewrite(string $sql, array $params): array
    {
        $out = '';
        $orderedNames = [];
        $indexByName = [];
        $length = strlen($sql);
        $i = 0;

        while ($i < $length) {
            $char = $sql[$i];

            // --- single-quoted string literal ---------------------------------
            if ($char === "'") {
                [$literal, $i] = $this->consumeQuoted($sql, $i, "'");
                $out .= $literal;
                continue;
            }

            // --- double-quoted identifier -------------------------------------
            if ($char === '"') {
                [$literal, $i] = $this->consumeQuoted($sql, $i, '"');
                $out .= $literal;
                continue;
            }

            // --- dollar-quoted string ($tag$ … $tag$) -------------------------
            if ($char === '$' && ($tag = $this->dollarTagAt($sql, $i)) !== null) {
                [$literal, $i] = $this->consumeDollarQuoted($sql, $i, $tag);
                $out .= $literal;
                continue;
            }

            // --- line comment (-- …) ------------------------------------------
            if ($char === '-' && ($sql[$i + 1] ?? '') === '-') {
                $end = strpos($sql, "\n", $i);
                $end = $end === false ? $length : $end;
                $out .= substr($sql, $i, $end - $i);
                $i = $end;
                continue;
            }

            // --- block comment (/* … */) --------------------------------------
            if ($char === '/' && ($sql[$i + 1] ?? '') === '*') {
                $end = strpos($sql, '*/', $i + 2);
                $end = $end === false ? $length : $end + 2;
                $out .= substr($sql, $i, $end - $i);
                $i = $end;
                continue;
            }

            // --- cast operator (::) -------------------------------------------
            if ($char === ':' && ($sql[$i + 1] ?? '') === ':') {
                $out .= '::';
                $i += 2;
                continue;
            }

            // --- named parameter (:name) --------------------------------------
            if ($char === ':' && preg_match('/[A-Za-z_]/', $sql[$i + 1] ?? '') === 1) {
                $j = $i + 1;
                while ($j < $length && preg_match('/[A-Za-z0-9_]/', $sql[$j]) === 1) {
                    $j++;
                }
                $name = substr($sql, $i + 1, $j - $i - 1);

                if (!array_key_exists($name, $indexByName)) {
                    $indexByName[$name] = count($orderedNames) + 1;
                    $orderedNames[] = $name;
                }

                $out .= '$' . $indexByName[$name];
                $i = $j;
                continue;
            }

            $out .= $char;
            $i++;
        }

        return [
            'sql' => $out,
            'params' => $this->bindValues($orderedNames, $params),
        ];
    }

    /**
     * @param list<string>         $orderedNames
     * @param array<string, mixed> $params
     *
     * @return list<mixed>
     */
    private function bindValues(array $orderedNames, array $params): array
    {
        $values = [];

        foreach ($orderedNames as $name) {
            if (!array_key_exists($name, $params)) {
                throw new InvalidArgumentException(sprintf('Missing value for named parameter ":%s".', $name));
            }
            $values[] = $params[$name];
        }

        $unused = array_diff(array_keys($params), $orderedNames);
        if ($unused !== []) {
            throw new InvalidArgumentException(sprintf(
                'Unused named parameter(s): %s.',
                implode(', ', array_map(static fn (string $n): string => ':' . $n, $unused)),
            ));
        }

        return $values;
    }

    /**
     * Consume a single- or double-quoted run starting at $start (which points at
     * the opening quote). Handles doubled-quote escapes ('' and "").
     *
     * @return array{0: string, 1: int} the literal text and the index after it
     */
    private function consumeQuoted(string $sql, int $start, string $quote): array
    {
        $length = strlen($sql);
        $i = $start + 1;

        while ($i < $length) {
            if ($sql[$i] === $quote) {
                // Doubled quote is an escaped quote, not a terminator.
                if (($sql[$i + 1] ?? '') === $quote) {
                    $i += 2;
                    continue;
                }
                $i++;
                break;
            }
            $i++;
        }

        return [substr($sql, $start, $i - $start), $i];
    }

    /**
     * If a dollar-quote delimiter starts at $pos, return it (e.g. "$$" or "$tag$").
     * Returns null when the `$` is not a dollar-quote opener.
     */
    private function dollarTagAt(string $sql, int $pos): ?string
    {
        if (preg_match('/\$([A-Za-z_][A-Za-z0-9_]*)?\$/', $sql, $m, PREG_OFFSET_CAPTURE, $pos) !== 1) {
            return null;
        }

        // Only treat it as a delimiter if it starts exactly at $pos.
        return $m[0][1] === $pos ? $m[0][0] : null;
    }

    /**
     * @return array{0: string, 1: int}
     */
    private function consumeDollarQuoted(string $sql, int $start, string $tag): array
    {
        $close = strpos($sql, $tag, $start + strlen($tag));

        if ($close === false) {
            return [substr($sql, $start), strlen($sql)];
        }

        $end = $close + strlen($tag);

        return [substr($sql, $start, $end - $start), $end];
    }
}
