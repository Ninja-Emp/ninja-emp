<?php

declare(strict_types=1);

namespace EmpPos\Bootstrap;

final class Kernel
{
    public function health(): string
    {
        return "ok\n";
    }
}
