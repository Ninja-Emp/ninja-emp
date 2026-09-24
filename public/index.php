<?php

declare(strict_types=1);

require_once dirname(__DIR__) . '/src/Bootstrap/Kernel.php';

header('Content-Type: text/plain; charset=utf-8');
echo (new EmpPos\Bootstrap\Kernel())->health();
