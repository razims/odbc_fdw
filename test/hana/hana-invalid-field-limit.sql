CREATE SERVER invalid_field_limit FOREIGN DATA WRAPPER odbc_fdw
    OPTIONS (max_field_size '-1');
