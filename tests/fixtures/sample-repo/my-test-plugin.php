<?php
/**
 * Plugin Name: My Test Plugin
 * Plugin URI:  https://github.com/cairocoder01/my-test-plugin
 * Description: Sample plugin for loop-engineer fixture testing.
 * Version:     0.1.0
 * Author:      Test Author
 * Text Domain: my-test-plugin
 */

if ( ! defined( 'ABSPATH' ) ) {
    exit;
}

require_once( get_template_directory() . '/dt-core/libraries/class-builtins.php' );

add_filter( 'dt_post_type_modules', function ( $modules ) {
    $modules['my_test_module_base'] = [
        'name'          => __( 'My Test Module', 'my-test-plugin' ),
        'enabled'       => true,
        'locked'        => true,
        'prerequisites' => [ 'contacts_base' ],
        'post_type'     => 'contacts',
        'description'   => __( 'Test module for fixture testing.', 'my-test-plugin' ),
    ];
    return $modules;
}, 20, 1 );
