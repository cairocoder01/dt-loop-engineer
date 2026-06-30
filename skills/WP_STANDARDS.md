# DT Agent Standards

**PHP style, indentation, and project-specific patterns** are defined by the repo's own config files already provided in the Repository Context above — `AGENTS.md` / `CLAUDE.md`, `.phpcs.xml`, `.editorconfig`, and `phpunit.xml`. Those take precedence over anything in this document. This document covers only Disciple.Tools-specific APIs and non-negotiable rules that apply across every DT repo.

---

## 1. DT-Specific APIs

### Post Type Registration

All custom post types must extend `DT_Module_Base` and register via the `dt_post_type_modules` filter. Never register a custom post type outside this system.

```php
add_filter( 'dt_post_type_modules', function( $modules ) {
    $modules['my_module_base'] = [
        'name'          => __( 'My Feature', 'my-text-domain' ),
        'enabled'       => true,
        'locked'        => true,
        'prerequisites' => [ 'contacts_base' ],
        'post_type'     => 'my_post_type',
        'description'   => __( 'Description', 'my-text-domain' ),
    ];
    return $modules;
}, 20, 1 );
```

### DT_Posts API

Use these methods for all post CRUD. Never write raw SQL for operations covered here.

```php
DT_Posts::create_post( $post_type, $fields )
DT_Posts::get_post( $post_type, $post_id )
DT_Posts::update_post( $post_type, $post_id, $fields )
DT_Posts::list_posts( $post_type, $query_array )
DT_Posts::can_view( $post_type, $post_id )   // always check before returning data
DT_Posts::can_create( $post_type )
```

### Field Value Formats (for create/update)

These array shapes are DT-specific — the model will not know them from general WP knowledge.

```php
// key_select — pass the key directly
$fields['status'] = 'active';

// multi_select / tags — values array; force_values=true replaces all existing
$fields['milestones'] = [ 'values' => [ [ 'value' => 'key' ] ], 'force_values' => true ];

// connection — add or remove links to other posts
$fields['groups'] = [ 'values' => [ [ 'value' => 123 ], [ 'value' => 456, 'delete' => true ] ] ];

// communication channel (phone, email, etc.)
$fields['contact_phone'] = [ 'values' => [ [ 'value' => '555-1234', 'verified' => true ] ] ];

// date — YYYY-MM-DD string or Unix timestamp
$fields['start_date'] = '2024-01-15';

// user_select — integer user ID
$fields['assigned_to'] = $user_id;
```

### list_posts() Query Format

```php
DT_Posts::list_posts( 'contacts', [
    'offset'         => 0,
    'limit'          => 50,
    'sort'           => '-last_modified',       // prefix - for descending
    'overall_status' => [ 'active' ],           // match any of these keys
    'milestones'     => [ '-key' ],             // NOT this key
    'milestones'     => [ '*' ],                // has ANY value
    'milestones'     => [],                     // has NO values
    'assigned_to'    => [ 'me' ],              // current user
    'last_modified'  => [ 'start' => '2024-01-01', 'end' => '2024-12-31' ],
    'member_count'   => [ 'number' => 5, 'operator' => '>=' ],
    'text'           => 'search term',
] );
```

### Field Definition (dt_custom_fields_settings filter)

```php
$fields['my_field'] = [
    'name'           => __( 'My Field', 'my-text-domain' ),
    'type'           => 'key_select',  // text|textarea|number|date|key_select|multi_select|tags|connection|location|user_select|communication_channel
    'tile'           => 'details',
    'default'        => [ 'option_a' => [ 'label' => __( 'Option A', 'my-text-domain' ) ] ],
    'customizable'   => false,
    'in_create_form' => true,
];
```

### REST Endpoints

Always use this permission pattern — never `__return_true`.

```php
'permission_callback' => function() {
    return current_user_can( 'access_contacts' ) || current_user_can( 'dt_all_access_contacts' );
}
```

Plugin namespace: `/my-plugin-name/v1/`. Public (no-auth) endpoints only under `/dt-public/v1/` for magic link flows.

### Useful DT Globals

```php
dt_write_log( $data );                  // debug logging (WP_DEBUG must be true)
dt_is_rest();                           // bool — is this a REST request?
dt_recursive_sanitize_array( $array );  // deep-sanitize an input array
disciple_tools();                       // Disciple_Tools singleton instance
```

Activity hooks: `dt_post_update_fields`, `dt_post_created`, `post_connection_added`, `post_connection_removed`.

---

## 2. One-Line Rules

- **PHP style:** Follow `.phpcs.xml` and `.editorconfig` in this repo — run `./tests/test_phpcs.sh` before marking complete.
- **Escaping:** `esc_html()`, `esc_attr()`, `esc_url()` on every value touching HTML. No exceptions.
- **Sanitizing:** `sanitize_text_field()`, `absint()`, or `dt_recursive_sanitize_array()` on all user input at REST/form boundaries.
- **Translations:** Every user-facing string uses `__()` / `esc_html_e()` / `esc_html__()` with the repo's text domain.
- **Frontend:** Run `npm run lint` and `npm run prettier` before marking complete.
- **Tests:** `WP_MULTISITE=1 vendor/bin/phpunit`. Never mock the database in integration tests.

---

## 3. Never Do

- Drop or alter existing database tables
- Change an existing field's `type` or rename its key (stored in postmeta, requires migration)
- Rename existing post type slugs (stored in `wp_posts.post_type`)
- Remove or rename existing filter/action hooks
- Modify the module-loading block in `functions.php`
- Write raw SQL for any operation covered by `DT_Posts`
- Use `__return_true` as a REST permission callback
- Create functions or classes without a plugin/theme prefix
- Modify files in `vendor/`, `node_modules/`, `dt-core/libraries/`, or `dt-core/dependencies/`
- Remove existing PHPUnit tests — only add or update them
- Commit `.env` files, credentials, or API keys
- Install new Composer or npm packages without noting them in the blueprint

---

## 4. PR Readiness Checklist

Before writing `COMPLETE` in `PROGRESS.md`:

- [ ] `php -l` passes on all modified PHP files
- [ ] PHPCS passes (`./tests/test_phpcs.sh`)
- [ ] `WP_MULTISITE=1 vendor/bin/phpunit` passes
- [ ] All user-facing strings use translation functions with the correct text domain
- [ ] All output is escaped; all user input is sanitized
- [ ] REST endpoints check capabilities before mutating data
- [ ] No hardcoded credentials, absolute paths, or magic strings
