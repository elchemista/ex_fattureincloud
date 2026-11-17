# Endpoint disponibili

Generato da `scripts/generate.py`. Non modificare manualmente.

Ogni funzione riceve `client`, i parametri del percorso nell'ordine indicato,
il body (se previsto) e infine `opts \\ []` per i parametri query.

I body JSON mantengono l'envelope ufficiale, es. `%{data: %{name: "Rossi"}}`.
Per gli upload il body è una lista di campi multipart Req.

| Modulo | Funzione e argomenti dopo client | HTTP | Percorso |
| --- | --- | --- | --- |
| `Archive` | `list_archive_documents(company_id, opts)` | GET | `/c/{company_id}/archive` |
| `Archive` | `create_archive_document(company_id, body, opts)` | POST | `/c/{company_id}/archive` |
| `Archive` | `upload_archive_document_attachment(company_id, body, opts)` | POST | `/c/{company_id}/archive/attachment` |
| `Archive` | `delete_archive_document(company_id, document_id, opts)` | DELETE | `/c/{company_id}/archive/{document_id}` |
| `Archive` | `get_archive_document(company_id, document_id, opts)` | GET | `/c/{company_id}/archive/{document_id}` |
| `Archive` | `modify_archive_document(company_id, document_id, body, opts)` | PUT | `/c/{company_id}/archive/{document_id}` |
| `IssuedDocuments` | `list_bin_issued_documents(company_id, opts)` | GET | `/c/{company_id}/bin/issued_documents` |
| `IssuedDocuments` | `delete_bin_issued_document(company_id, document_id, opts)` | DELETE | `/c/{company_id}/bin/issued_documents/{document_id}` |
| `IssuedDocuments` | `get_bin_issued_document(company_id, document_id, opts)` | GET | `/c/{company_id}/bin/issued_documents/{document_id}` |
| `IssuedDocuments` | `recover_bin_issued_document(company_id, document_id, opts)` | POST | `/c/{company_id}/bin/issued_documents/{document_id}/recover` |
| `ReceivedDocuments` | `list_bin_received_documents(company_id, opts)` | GET | `/c/{company_id}/bin/received_documents` |
| `ReceivedDocuments` | `delete_bin_received_document(company_id, document_id, opts)` | DELETE | `/c/{company_id}/bin/received_documents/{document_id}` |
| `ReceivedDocuments` | `get_bin_received_document(company_id, document_id, opts)` | GET | `/c/{company_id}/bin/received_documents/{document_id}` |
| `ReceivedDocuments` | `recover_bin_received_document(company_id, document_id, opts)` | POST | `/c/{company_id}/bin/received_documents/{document_id}/recover` |
| `Cashbook` | `list_cashbook_entries(company_id, opts)` | GET | `/c/{company_id}/cashbook` |
| `Cashbook` | `create_cashbook_entry(company_id, body, opts)` | POST | `/c/{company_id}/cashbook` |
| `Cashbook` | `delete_cashbook_entry(company_id, document_id, opts)` | DELETE | `/c/{company_id}/cashbook/{document_id}` |
| `Cashbook` | `get_cashbook_entry(company_id, document_id, opts)` | GET | `/c/{company_id}/cashbook/{document_id}` |
| `Cashbook` | `modify_cashbook_entry(company_id, document_id, body, opts)` | PUT | `/c/{company_id}/cashbook/{document_id}` |
| `Companies` | `get_company_info(company_id, opts)` | GET | `/c/{company_id}/company/info` |
| `Companies` | `get_company_plan_usage(company_id, opts)` | GET | `/c/{company_id}/company/plan_usage` |
| `Emails` | `list_emails(company_id, opts)` | GET | `/c/{company_id}/emails` |
| `Clients` | `list_clients(company_id, opts)` | GET | `/c/{company_id}/entities/clients` |
| `Clients` | `create_client(company_id, body, opts)` | POST | `/c/{company_id}/entities/clients` |
| `Clients` | `get_client_info(company_id, opts)` | GET | `/c/{company_id}/entities/clients/info` |
| `Clients` | `delete_client(company_id, client_id, opts)` | DELETE | `/c/{company_id}/entities/clients/{client_id}` |
| `Clients` | `get_client(company_id, client_id, opts)` | GET | `/c/{company_id}/entities/clients/{client_id}` |
| `Clients` | `modify_client(company_id, client_id, body, opts)` | PUT | `/c/{company_id}/entities/clients/{client_id}` |
| `Suppliers` | `list_suppliers(company_id, opts)` | GET | `/c/{company_id}/entities/suppliers` |
| `Suppliers` | `create_supplier(company_id, body, opts)` | POST | `/c/{company_id}/entities/suppliers` |
| `Suppliers` | `delete_supplier(company_id, supplier_id, opts)` | DELETE | `/c/{company_id}/entities/suppliers/{supplier_id}` |
| `Suppliers` | `get_supplier(company_id, supplier_id, opts)` | GET | `/c/{company_id}/entities/suppliers/{supplier_id}` |
| `Suppliers` | `modify_supplier(company_id, supplier_id, body, opts)` | PUT | `/c/{company_id}/entities/suppliers/{supplier_id}` |
| `Companies` | `get_api_usage(company_id, opts)` | GET | `/c/{company_id}/info/api_usage` |
| `Info` | `list_archive_categories(company_id, opts)` | GET | `/c/{company_id}/info/archive_categories` |
| `Info` | `list_cost_centers(company_id, opts)` | GET | `/c/{company_id}/info/cost_centers` |
| `Info` | `list_payment_accounts(company_id, opts)` | GET | `/c/{company_id}/info/payment_accounts` |
| `Info` | `list_payment_methods(company_id, opts)` | GET | `/c/{company_id}/info/payment_methods` |
| `Info` | `list_product_categories(company_id, opts)` | GET | `/c/{company_id}/info/product_categories` |
| `Info` | `list_received_document_categories(company_id, opts)` | GET | `/c/{company_id}/info/received_document_categories` |
| `Info` | `list_revenue_centers(company_id, opts)` | GET | `/c/{company_id}/info/revenue_centers` |
| `Info` | `list_vat_types(company_id, opts)` | GET | `/c/{company_id}/info/vat_types` |
| `IssuedDocuments` | `list_issued_documents(company_id, opts)` | GET | `/c/{company_id}/issued_documents` |
| `IssuedDocuments` | `create_issued_document(company_id, body, opts)` | POST | `/c/{company_id}/issued_documents` |
| `IssuedDocuments` | `upload_issued_document_attachment(company_id, body, opts)` | POST | `/c/{company_id}/issued_documents/attachment` |
| `IssuedDocuments` | `get_issued_document_pre_create_info(company_id, opts)` | GET | `/c/{company_id}/issued_documents/info` |
| `IssuedDocuments` | `join_issued_documents(company_id, opts)` | GET | `/c/{company_id}/issued_documents/join` |
| `IssuedDocuments` | `get_new_issued_document_totals(company_id, body, opts)` | POST | `/c/{company_id}/issued_documents/totals` |
| `IssuedDocuments` | `transform_issued_document(company_id, opts)` | GET | `/c/{company_id}/issued_documents/transform` |
| `IssuedDocuments` | `delete_issued_document(company_id, document_id, opts)` | DELETE | `/c/{company_id}/issued_documents/{document_id}` |
| `IssuedDocuments` | `get_issued_document(company_id, document_id, opts)` | GET | `/c/{company_id}/issued_documents/{document_id}` |
| `IssuedDocuments` | `modify_issued_document(company_id, document_id, body, opts)` | PUT | `/c/{company_id}/issued_documents/{document_id}` |
| `IssuedDocuments` | `delete_issued_document_attachment(company_id, document_id, opts)` | DELETE | `/c/{company_id}/issued_documents/{document_id}/attachment` |
| `IssuedEInvoices` | `get_e_invoice_rejection_reason(company_id, document_id, opts)` | GET | `/c/{company_id}/issued_documents/{document_id}/e_invoice/error_reason` |
| `IssuedEInvoices` | `send_e_invoice(company_id, document_id, body, opts)` | POST | `/c/{company_id}/issued_documents/{document_id}/e_invoice/send` |
| `IssuedEInvoices` | `get_e_invoice_xml(company_id, document_id, opts)` | GET | `/c/{company_id}/issued_documents/{document_id}/e_invoice/xml` |
| `IssuedEInvoices` | `verify_e_invoice_xml(company_id, document_id, opts)` | GET | `/c/{company_id}/issued_documents/{document_id}/e_invoice/xml_verify` |
| `IssuedDocuments` | `get_email_data(company_id, document_id, opts)` | GET | `/c/{company_id}/issued_documents/{document_id}/email` |
| `IssuedDocuments` | `schedule_email(company_id, document_id, body, opts)` | POST | `/c/{company_id}/issued_documents/{document_id}/email` |
| `IssuedDocuments` | `get_existing_issued_document_totals(company_id, document_id, body, opts)` | POST | `/c/{company_id}/issued_documents/{document_id}/totals` |
| `PriceLists` | `get_price_lists(company_id, opts)` | GET | `/c/{company_id}/price_lists` |
| `PriceLists` | `get_price_list_items(company_id, price_list_id, opts)` | GET | `/c/{company_id}/price_lists/{price_list_id}/items` |
| `Products` | `list_products(company_id, opts)` | GET | `/c/{company_id}/products` |
| `Products` | `create_product(company_id, body, opts)` | POST | `/c/{company_id}/products` |
| `Products` | `delete_product(company_id, product_id, opts)` | DELETE | `/c/{company_id}/products/{product_id}` |
| `Products` | `get_product(company_id, product_id, opts)` | GET | `/c/{company_id}/products/{product_id}` |
| `Products` | `modify_product(company_id, product_id, body, opts)` | PUT | `/c/{company_id}/products/{product_id}` |
| `Receipts` | `list_receipts(company_id, opts)` | GET | `/c/{company_id}/receipts` |
| `Receipts` | `create_receipt(company_id, body, opts)` | POST | `/c/{company_id}/receipts` |
| `Receipts` | `get_receipt_pre_create_info(company_id, opts)` | GET | `/c/{company_id}/receipts/info` |
| `Receipts` | `get_receipts_monthly_totals(company_id, opts)` | GET | `/c/{company_id}/receipts/monthly_totals` |
| `Receipts` | `delete_receipt(company_id, document_id, opts)` | DELETE | `/c/{company_id}/receipts/{document_id}` |
| `Receipts` | `get_receipt(company_id, document_id, opts)` | GET | `/c/{company_id}/receipts/{document_id}` |
| `Receipts` | `modify_receipt(company_id, document_id, body, opts)` | PUT | `/c/{company_id}/receipts/{document_id}` |
| `ReceivedDocuments` | `list_received_documents(company_id, opts)` | GET | `/c/{company_id}/received_documents` |
| `ReceivedDocuments` | `create_received_document(company_id, body, opts)` | POST | `/c/{company_id}/received_documents` |
| `ReceivedDocuments` | `upload_received_document_attachment(company_id, body, opts)` | POST | `/c/{company_id}/received_documents/attachment` |
| `ReceivedDocuments` | `get_received_document_pre_create_info(company_id, opts)` | GET | `/c/{company_id}/received_documents/info` |
| `ReceivedDocuments` | `list_pending_received_documents(company_id, opts)` | GET | `/c/{company_id}/received_documents/pending` |
| `ReceivedDocuments` | `get_pending_received_document(company_id, document_id, opts)` | GET | `/c/{company_id}/received_documents/pending/{document_id}` |
| `ReceivedDocuments` | `get_new_received_document_totals(company_id, body, opts)` | POST | `/c/{company_id}/received_documents/totals` |
| `ReceivedDocuments` | `delete_received_document(company_id, document_id, opts)` | DELETE | `/c/{company_id}/received_documents/{document_id}` |
| `ReceivedDocuments` | `get_received_document(company_id, document_id, opts)` | GET | `/c/{company_id}/received_documents/{document_id}` |
| `ReceivedDocuments` | `modify_received_document(company_id, document_id, body, opts)` | PUT | `/c/{company_id}/received_documents/{document_id}` |
| `ReceivedDocuments` | `delete_received_document_attachment(company_id, document_id, opts)` | DELETE | `/c/{company_id}/received_documents/{document_id}/attachment` |
| `ReceivedDocuments` | `get_existing_received_document_totals(company_id, document_id, body, opts)` | POST | `/c/{company_id}/received_documents/{document_id}/totals` |
| `Settings` | `create_payment_account(company_id, body, opts)` | POST | `/c/{company_id}/settings/payment_accounts` |
| `Settings` | `delete_payment_account(company_id, payment_account_id, opts)` | DELETE | `/c/{company_id}/settings/payment_accounts/{payment_account_id}` |
| `Settings` | `get_payment_account(company_id, payment_account_id, opts)` | GET | `/c/{company_id}/settings/payment_accounts/{payment_account_id}` |
| `Settings` | `modify_payment_account(company_id, payment_account_id, body, opts)` | PUT | `/c/{company_id}/settings/payment_accounts/{payment_account_id}` |
| `Settings` | `create_payment_method(company_id, body, opts)` | POST | `/c/{company_id}/settings/payment_methods` |
| `Settings` | `delete_payment_method(company_id, payment_method_id, opts)` | DELETE | `/c/{company_id}/settings/payment_methods/{payment_method_id}` |
| `Settings` | `get_payment_method(company_id, payment_method_id, opts)` | GET | `/c/{company_id}/settings/payment_methods/{payment_method_id}` |
| `Settings` | `modify_payment_method(company_id, payment_method_id, body, opts)` | PUT | `/c/{company_id}/settings/payment_methods/{payment_method_id}` |
| `Settings` | `get_tax_profile(company_id, opts)` | GET | `/c/{company_id}/settings/tax_profile` |
| `Settings` | `list_templates(company_id, opts)` | GET | `/c/{company_id}/settings/templates` |
| `Settings` | `get_template(company_id, template_id, opts)` | GET | `/c/{company_id}/settings/templates/{template_id}` |
| `Settings` | `create_vat_type(company_id, body, opts)` | POST | `/c/{company_id}/settings/vat_types` |
| `Settings` | `delete_vat_type(company_id, vat_type_id, opts)` | DELETE | `/c/{company_id}/settings/vat_types/{vat_type_id}` |
| `Settings` | `get_vat_type(company_id, vat_type_id, opts)` | GET | `/c/{company_id}/settings/vat_types/{vat_type_id}` |
| `Settings` | `modify_vat_type(company_id, vat_type_id, body, opts)` | PUT | `/c/{company_id}/settings/vat_types/{vat_type_id}` |
| `Webhooks` | `list_webhooks_subscriptions(company_id, opts)` | GET | `/c/{company_id}/subscriptions` |
| `Webhooks` | `create_webhooks_subscription(company_id, body, opts)` | POST | `/c/{company_id}/subscriptions` |
| `Webhooks` | `delete_webhooks_subscription(company_id, subscription_id, opts)` | DELETE | `/c/{company_id}/subscriptions/{subscription_id}` |
| `Webhooks` | `get_webhooks_subscription(company_id, subscription_id, opts)` | GET | `/c/{company_id}/subscriptions/{subscription_id}` |
| `Webhooks` | `modify_webhooks_subscription(company_id, subscription_id, body, opts)` | PUT | `/c/{company_id}/subscriptions/{subscription_id}` |
| `Webhooks` | `verify_webhooks_subscription(company_id, subscription_id, body, opts)` | POST | `/c/{company_id}/subscriptions/{subscription_id}/verify` |
| `Taxes` | `list_f24(company_id, opts)` | GET | `/c/{company_id}/taxes` |
| `Taxes` | `create_f24(company_id, body, opts)` | POST | `/c/{company_id}/taxes` |
| `Taxes` | `upload_f24_attachment(company_id, body, opts)` | POST | `/c/{company_id}/taxes/attachment` |
| `Taxes` | `delete_f24(company_id, document_id, opts)` | DELETE | `/c/{company_id}/taxes/{document_id}` |
| `Taxes` | `get_f24(company_id, document_id, opts)` | GET | `/c/{company_id}/taxes/{document_id}` |
| `Taxes` | `modify_f24(company_id, document_id, body, opts)` | PUT | `/c/{company_id}/taxes/{document_id}` |
| `Taxes` | `delete_f24_attachment(company_id, document_id, opts)` | DELETE | `/c/{company_id}/taxes/{document_id}/attachment` |
| `Info` | `list_cities(opts)` | GET | `/info/cities` |
| `Info` | `list_countries(opts)` | GET | `/info/countries` |
| `Info` | `list_currencies(opts)` | GET | `/info/currencies` |
| `Info` | `list_detailed_countries(opts)` | GET | `/info/detailed_countries` |
| `Info` | `list_delivery_notes_default_causals(opts)` | GET | `/info/dn_causals` |
| `Info` | `list_languages(opts)` | GET | `/info/languages` |
| `Info` | `list_units_of_measure(opts)` | GET | `/info/measures` |
| `Info` | `list_default_templates(opts)` | GET | `/info/templates` |
| `User` | `list_user_companies(opts)` | GET | `/user/companies` |
| `User` | `get_user_info(opts)` | GET | `/user/info` |
