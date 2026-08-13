CREATE SERVER invalid_limit FOREIGN DATA WRAPPER odbc_fdw
    OPTIONS (max_result_size '-1');
