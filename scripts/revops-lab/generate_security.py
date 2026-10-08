"""Generates the Revenue Operations Lab permission sets, permission set groups and the field-level security
document from ONE access matrix, so the metadata and the documentation cannot drift apart.

Usage (from the repository root):  python3 scripts/revops-lab/generate_security.py
Re-run after changing the matrix below and commit the generated files together with this script.

Rules encoded here
  * Required fields and master-detail fields are not permissionable (the platform always grants them), so they
    are listed in REQUIRED and documented, not written to permission sets.
  * System-owned fields (status, approval, pricing outputs, ERP bookkeeping) are read-only for every persona.
    Apex writes them; FLS stops people from doing so through the UI or API.
"""
import os

ROOT = 'revops-lab/main/default'
DOC = 'docs/revops-lab/FIELD-LEVEL-SECURITY.md'

# Persona permission sets: (api name, label, description)
SETS = {
    'Sales_Lab_Base': ('Sales Lab Base', 'Catalogue, discount policy and app access shared by every human persona.'),
    'Sales_Representative_Access': ('Sales Representative Access', 'Create and edit own quotes and lines, submit, convert approved quotes.'),
    'Sales_Manager_Access': ('Sales Manager Access', 'Team oversight through the role hierarchy; delete quotes; tier 1 approver.'),
    'Finance_Manager_Access': ('Finance Manager Access', 'Reviews submitted quotes (sharing rule), tier 2 approver, maintains discount policies.'),
    'Sales_Director_Access': ('Sales Director Access', 'Top of the role hierarchy; tier 3 approver.'),
    'Sales_Integration_Access': ('Sales Integration Access', 'ERP integration user: reads orders and accounts, writes ERP bookkeeping and integration logs.'),
    'Sales_Administrator_Access': ('Sales Administrator Access', 'Lab administration, catalogue maintenance, break-glass override and manual ERP sync.'),
}

# Permission set groups: (api name, label, included sets)
GROUPS = [
    ('Sales_Representative_PSG', 'Sales Representative', ['Sales_Lab_Base', 'Sales_Representative_Access']),
    ('Sales_Manager_PSG', 'Sales Manager', ['Sales_Lab_Base', 'Sales_Representative_Access', 'Sales_Manager_Access']),
    ('Finance_Manager_PSG', 'Finance Manager', ['Sales_Lab_Base', 'Finance_Manager_Access']),
    ('Sales_Director_PSG', 'Sales Director', ['Sales_Lab_Base', 'Sales_Representative_Access', 'Sales_Manager_Access', 'Sales_Director_Access']),
    ('Sales_Integration_PSG', 'Sales Integration User', ['Sales_Integration_Access']),
    ('Sales_Administrator_PSG', 'Salesforce Administrator (Lab)', ['Sales_Lab_Base', 'Sales_Administrator_Access']),
]
PERSONAS = [g[0] for g in GROUPS]
PERSONA_LABEL = {g[0]: g[1] for g in GROUPS}

# Object permissions: C create, R read, E edit, D delete, V view all, M modify all
OBJECTS = {
    'Sales_Lab_Base': {'Account': 'R', 'Contact': 'R', 'Opportunity': 'R', 'Product2': 'R', 'Pricebook2': 'R', 'Discount_Policy__c': 'R'},
    'Sales_Representative_Access': {'Account': 'CRE', 'Contact': 'CRE', 'Opportunity': 'CRE', 'Order': 'CRE',
                                    'Quote_Configuration__c': 'CRE', 'Quote_Configuration_Line__c': 'CRED',
                                    'Sales_Approval_Request__c': 'R', 'Sales_Subscription__c': 'R'},
    'Sales_Manager_Access': {'Account': 'R', 'Quote_Configuration__c': 'CRED', 'Sales_Approval_Request__c': 'RE', 'Sales_Subscription__c': 'R'},
    'Finance_Manager_Access': {'Account': 'R', 'Quote_Configuration__c': 'RE', 'Quote_Configuration_Line__c': 'R', 'Sales_Approval_Request__c': 'RE',
                               'Order': 'R', 'Sales_Subscription__c': 'R', 'Discount_Policy__c': 'CRE'},
    'Sales_Director_Access': {'Quote_Configuration__c': 'CRED', 'Sales_Approval_Request__c': 'RE'},
    'Sales_Integration_Access': {'Account': 'RV', 'Order': 'REV', 'Product2': 'R', 'Sales_Integration_Log__c': 'CRE'},
    'Sales_Administrator_Access': {'Account': 'CREDV', 'Contact': 'CREDV', 'Opportunity': 'CREDV', 'Order': 'CREDV',
                                   'Product2': 'CRE', 'Pricebook2': 'CRE',
                                   'Quote_Configuration__c': 'CREDV', 'Quote_Configuration_Line__c': 'CREDV',
                                   'Sales_Approval_Request__c': 'REV', 'Discount_Policy__c': 'CREDV',
                                   'Sales_Integration_Log__c': 'CREDVM', 'Sales_Subscription__c': 'CREDV'},
}

# Field permissions per set: field -> 'R' or 'E'
_RO_QUOTE = ['Status__c', 'Approval_Required__c', 'Required_Approval_Tier__c', 'Approval_Threshold_Percent__c', 'Total_List_Amount__c',
             'Total_Net_Amount__c', 'Max_Discount_Percent__c', 'Line_Count__c', 'Total_Discount_Amount__c', 'Blended_Discount_Percent__c',
             'Order__c', 'Submitted_Date__c', 'Approved_Date__c']
_USER_QUOTE = ['Account__c', 'Price_Book__c', 'Primary_Contact__c', 'Term_Months__c', 'Valid_Until__c', 'Customer_PO_Number__c']
_RO_LINE = ['Price_Book_Entry_Id__c', 'Product_Family__c', 'Billing_Frequency__c', 'List_Unit_Price__c', 'Max_Allowed_Discount_Percent__c',
            'List_Total__c', 'Net_Unit_Price__c', 'Net_Total__c']
_APPROVAL = ['Approver__c', 'Requested_By__c', 'Status__c', 'Approval_Tier__c', 'Requested_Discount_Percent__c', 'Threshold_Percent__c',
             'Quote_Amount__c', 'Comments__c', 'Submitted_Date__c', 'Decision_Date__c']
_POLICY = ['Effective_To__c', 'Active__c', 'Notes__c']
_LOG = ['Correlation_Id__c', 'Integration_Name__c', 'Direction__c', 'Http_Method__c', 'Endpoint__c', 'Http_Status_Code__c', 'Outcome__c',
        'Attempt__c', 'Duration_Ms__c', 'Related_Record_Id__c', 'Request_Body__c', 'Response_Body__c', 'Error_Message__c']
_SUB = ['Product__c', 'Order__c', 'Quote_Configuration__c', 'Quantity__c', 'Annual_Value__c', 'Start_Date__c', 'End_Date__c', 'Status__c']
_ORDER_ERP = ['ERP_Sync_Status__c', 'ERP_Order_Number__c', 'ERP_Retry_Count__c', 'ERP_Next_Retry_At__c', 'ERP_Last_Error__c']


def fs(obj, names, level):
    return {f'{obj}.{n}': level for n in names}


FIELDS = {
    'Sales_Lab_Base': {
        **fs('Product2', ['Billing_Frequency__c', 'ERP_Item_Code__c'], 'R'), **fs('Pricebook2', ['Sales_Region__c'], 'R'),
        **fs('Discount_Policy__c', _POLICY, 'R'), **fs('Account', ['Customer_Segment__c', 'ERP_Account_Number__c'], 'R'),
        **fs('Contact', ['Buying_Role__c'], 'R'), **fs('Opportunity', ['Primary_Quote_Configuration__c'], 'R'),
    },
    'Sales_Representative_Access': {
        **fs('Quote_Configuration__c', _USER_QUOTE, 'E'), **fs('Quote_Configuration__c', _RO_QUOTE, 'R'),
        **fs('Quote_Configuration_Line__c', ['Product__c', 'Discount_Percent__c'], 'E'), **fs('Quote_Configuration_Line__c', _RO_LINE, 'R'),
        **fs('Sales_Approval_Request__c', _APPROVAL, 'R'), **fs('Sales_Subscription__c', _SUB, 'R'),
        **fs('Account', ['Customer_Segment__c'], 'E'), **fs('Contact', ['Buying_Role__c'], 'E'),
        **fs('Opportunity', ['Primary_Quote_Configuration__c'], 'E'),
        **fs('Order', ['Quote_Configuration__c'], 'E'), **fs('Order', _ORDER_ERP, 'R'),
    },
    'Sales_Manager_Access': {},
    'Finance_Manager_Access': {
        **fs('Quote_Configuration__c', _USER_QUOTE + _RO_QUOTE, 'R'), **fs('Quote_Configuration_Line__c', ['Product__c', 'Discount_Percent__c'] + _RO_LINE, 'R'),
        **fs('Sales_Approval_Request__c', _APPROVAL, 'R'), **fs('Discount_Policy__c', _POLICY, 'E'),
        **fs('Order', ['Quote_Configuration__c'] + _ORDER_ERP, 'R'), **fs('Sales_Subscription__c', _SUB, 'R'),
        **fs('Account', ['ERP_Account_Number__c'], 'E'),
    },
    'Sales_Director_Access': {},
    'Sales_Integration_Access': {
        **fs('Order', _ORDER_ERP, 'E'), **fs('Order', ['Quote_Configuration__c'], 'R'), **fs('Account', ['ERP_Account_Number__c'], 'R'),
        **fs('Product2', ['ERP_Item_Code__c', 'Billing_Frequency__c'], 'R'), **fs('Sales_Integration_Log__c', _LOG, 'E'),
    },
    'Sales_Administrator_Access': {
        **fs('Quote_Configuration__c', _USER_QUOTE, 'E'), **fs('Quote_Configuration__c', _RO_QUOTE, 'R'),
        **fs('Quote_Configuration_Line__c', ['Product__c', 'Discount_Percent__c'], 'E'), **fs('Quote_Configuration_Line__c', _RO_LINE, 'R'),
        **fs('Sales_Approval_Request__c', _APPROVAL, 'R'), **fs('Discount_Policy__c', _POLICY, 'E'),
        **fs('Sales_Integration_Log__c', _LOG, 'E'), **fs('Sales_Subscription__c', _SUB, 'E'),
        **fs('Account', ['Customer_Segment__c', 'ERP_Account_Number__c'], 'E'), **fs('Contact', ['Buying_Role__c'], 'E'),
        **fs('Opportunity', ['Primary_Quote_Configuration__c'], 'E'), **fs('Order', ['Quote_Configuration__c'], 'E'),
        **fs('Order', _ORDER_ERP, 'E'), **fs('Product2', ['Billing_Frequency__c', 'ERP_Item_Code__c'], 'E'),
        **fs('Pricebook2', ['Sales_Region__c'], 'E'),
    },
}

CUSTOM_PERMISSIONS = {
    'Finance_Manager_Access': ['Sales_Manage_Discount_Policy'],
    'Sales_Integration_Access': ['Sales_Run_ERP_Sync'],
    'Sales_Administrator_Access': ['Sales_Manage_Discount_Policy', 'Sales_Override_Quote_Lock', 'Sales_Run_ERP_Sync'],
}
APEX_CLASSES = {
    'Sales_Lab_Base': ['SalesApprovalController', 'SalesQuoteConfiguratorController'],
}
TABS = ['Discount_Policy__c', 'Quote_Configuration__c', 'Sales_Approval_Request__c', 'Sales_Integration_Log__c', 'Sales_Subscription__c']
APP_SETS = ['Sales_Lab_Base']

# Fields the platform always grants (required / master-detail): documented only.
REQUIRED = ['Quote_Configuration__c.Opportunity__c', 'Quote_Configuration_Line__c.Quote_Configuration__c', 'Quote_Configuration_Line__c.Quantity__c', 'Sales_Approval_Request__c.Quote_Configuration__c', 'Discount_Policy__c.Product_Family__c',
            'Discount_Policy__c.Max_Discount_Percent__c', 'Discount_Policy__c.Effective_From__c', 'Sales_Subscription__c.Account__c']

FLAG_ORDER = [('C', 'allowCreate'), ('D', 'allowDelete'), ('E', 'allowEdit'), ('R', 'allowRead'), ('M', 'modifyAllRecords'), ('V', 'viewAllRecords')]


def permission_set_xml(name):
    label, description = SETS[name]
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">']
    for app in (['RevOps_Lab'] if name in APP_SETS else []):
        out += ['    <applicationVisibilities>', f'        <application>{app}</application>', '        <visible>true</visible>', '    </applicationVisibilities>']
    for cls in sorted(APEX_CLASSES.get(name, [])):
        out += ['    <classAccesses>', f'        <apexClass>{cls}</apexClass>', '        <enabled>true</enabled>', '    </classAccesses>']
    for perm in sorted(CUSTOM_PERMISSIONS.get(name, [])):
        out += ['    <customPermissions>', '        <enabled>true</enabled>', f'        <name>{perm}</name>', '    </customPermissions>']
    out.append(f'    <description>{description}</description>')
    for field, level in sorted(FIELDS.get(name, {}).items()):
        assert field not in REQUIRED, field
        out += ['    <fieldPermissions>', f'        <editable>{"true" if level == "E" else "false"}</editable>', f'        <field>{field}</field>',
                '        <readable>true</readable>', '    </fieldPermissions>']
    out += ['    <hasActivationRequired>false</hasActivationRequired>', f'    <label>{label}</label>']
    for obj, flags in sorted(OBJECTS.get(name, {}).items()):
        out.append('    <objectPermissions>')
        for letter, tag in FLAG_ORDER:
            if tag == 'modifyAllRecords':
                out.append(f'        <{tag}>{"true" if letter in flags else "false"}</{tag}>')
                out.append(f'        <object>{obj}</object>')
            else:
                out.append(f'        <{tag}>{"true" if letter in flags else "false"}</{tag}>')
        out.append('    </objectPermissions>')
    if name in APP_SETS:
        for tab in TABS:
            out += ['    <tabSettings>', f'        <tab>{tab}</tab>', '        <visibility>Visible</visibility>', '    </tabSettings>']
    out.append('</PermissionSet>')
    return '\n'.join(out) + '\n'


def group_xml(name, label, sets):
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<PermissionSetGroup xmlns="http://soap.sforce.com/2006/04/metadata">',
           f'    <description>Persona group for the RevOps Lab: {label}.</description>', f'    <label>{label}</label>']
    out += [f'    <permissionSets>{s}</permissionSets>' for s in sets]
    out += ['    <status>Updated</status>', '</PermissionSetGroup>']
    return '\n'.join(out) + '\n'


def validate():
    for name, flags in ((n, f) for n, objs in OBJECTS.items() for f in objs.values()):
        if any(x in flags for x in 'CEDVM') and 'R' not in flags:
            raise SystemExit(f'{name}: every object permission needs Read ({flags})')
        if 'D' in flags and 'E' not in flags:
            raise SystemExit(f'{name}: Delete requires Edit ({flags})')
        if 'M' in flags and not all(x in flags for x in 'REDV'):
            raise SystemExit(f'{name}: Modify All requires Read, Edit, Delete and View All ({flags})')


def effective(group_sets):
    fields, objects, perms = {}, {}, set()
    for s in group_sets:
        for f, lvl in FIELDS.get(s, {}).items():
            fields[f] = 'E' if 'E' in (lvl, fields.get(f)) else 'R'
        for o, flags in OBJECTS.get(s, {}).items():
            objects[o] = ''.join(sorted(set(objects.get(o, '') + flags), key='CREDVM'.index))
        perms |= set(CUSTOM_PERMISSIONS.get(s, []))
    return fields, objects, perms


def doc():
    eff = {g: effective(sets) for g, _, sets in GROUPS}
    lines = ['# RevOps Lab - Object and Field-Level Security', '',
             '> Generated by `scripts/revops-lab/generate_security.py` from the same matrix that produces the permission sets. Do not edit by hand.',
             '> Status: deployable source. Not yet verified in an org - see [ORG-VALIDATION.md](../ORG-VALIDATION.md).', '',
             'Legend: **E** read and edit, **R** read only, **-** no access. Object letters: C create, R read, E edit, D delete, V view all, M modify all.', '',
             '## Object permissions by persona (effective, permission set group)', '',
             '| Object | ' + ' | '.join(PERSONA_LABEL[p] for p in PERSONAS) + ' |', '|---|' + '---|' * len(PERSONAS)]
    all_objects = sorted({o for objs in OBJECTS.values() for o in objs})
    for o in all_objects:
        lines.append(f'| `{o}` | ' + ' | '.join(eff[p][1].get(o, '-') or '-' for p in PERSONAS) + ' |')
    lines += ['', '## Field permissions by persona', '', '| Field | ' + ' | '.join(PERSONA_LABEL[p] for p in PERSONAS) + ' |', '|---|' + '---|' * len(PERSONAS)]
    all_fields = sorted({f for fs_ in FIELDS.values() for f in fs_})
    for f in all_fields:
        lines.append(f'| `{f}` | ' + ' | '.join(eff[p][0].get(f, '-') for p in PERSONAS) + ' |')
    lines += ['', '## Custom permissions by persona', '', '| Custom permission | ' + ' | '.join(PERSONA_LABEL[p] for p in PERSONAS) + ' |', '|---|' + '---|' * len(PERSONAS)]
    for cp in sorted({c for cs in CUSTOM_PERMISSIONS.values() for c in cs}):
        lines.append(f'| `{cp}` | ' + ' | '.join('yes' if cp in eff[p][2] else '-' for p in PERSONAS) + ' |')
    lines += ['', '## Not permissionable (always granted with object access)', '',
              'Required fields and master-detail fields cannot appear in permission sets; access follows the object permission:', '']
    lines += [f'* `{f}`' for f in REQUIRED]
    lines += ['', '## Why system-owned fields are read-only for everyone', '',
              'Status, approval, pricing outputs and ERP bookkeeping are written by Apex services after an explicit authorisation check',
              '(see [SECURITY.md](SECURITY.md)). Apex DML runs with CRUD/FLS in system mode, so read-only FLS does not block the services; it',
              'blocks people and API clients from setting those values directly. Record-level access (sharing) is still enforced because every',
              'service is `with sharing`.', '']
    return '\n'.join(lines)


def main():
    validate()
    os.makedirs(f'{ROOT}/permissionsets', exist_ok=True)
    os.makedirs(f'{ROOT}/permissionsetgroups', exist_ok=True)
    for name in SETS:
        with open(f'{ROOT}/permissionsets/{name}.permissionset-meta.xml', 'w') as handle:
            handle.write(permission_set_xml(name))
    for name, label, sets in GROUPS:
        with open(f'{ROOT}/permissionsetgroups/{name}.permissionsetgroup-meta.xml', 'w') as handle:
            handle.write(group_xml(name, label, sets))
    os.makedirs(os.path.dirname(DOC), exist_ok=True)
    with open(DOC, 'w') as handle:
        handle.write(doc())
    print(f'Wrote {len(SETS)} permission sets, {len(GROUPS)} groups and {DOC}')


if __name__ == '__main__':
    main()
