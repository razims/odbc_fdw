CREATE SERVER invalid_row_limit FOREIGN DATA WRAPPER odbc_fdw
    OPTIONS (max_row_count 'not-a-number');
