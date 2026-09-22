# Compatibility imports for existing configuration files and callers.
use RedSourcing::Config;
module RedSourcing::CLI::Config { }

sub EXPORT {
    Map(
        'Settings' => Settings,
        '&config' => &config,
        '&find-config' => &find-config,
        '&load-cli-config' => &load-cli-config,
        '&load-config' => &load-config,
        '&config-database' => &config-database,
        '&store-connection-options' => &store-connection-options,
        '&store-driver' => &store-driver,
        '&red-sourcing-defaults' => &red-sourcing-defaults,
    )
}
