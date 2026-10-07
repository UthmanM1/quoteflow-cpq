"""Static consistency check: every custom field referenced in a WITH USER_MODE query in QuoteSelector (main layer) or
SalesQuoteSelector (RevOps Lab) must be
readable by every persona permission-set group that calls into it. A field missing from a persona's FLS makes a
USER_MODE query throw at runtime, which no syntax check catches.

Usage: python3 scripts/ci/check_fls.py   (run from the repository root; exits 1 on any gap)
"""
import glob, os, re, sys

LAYERS = {
    'main': {
        'root': 'force-app/main/default',
        'selector': 'QuoteSelector',
        'relations': {'Account__r': 'Account', 'Product__r': 'Product2', 'Option_Product__r': 'Product2'},
        'personas': {
            'Sales rep': ['QF_Base_Access', 'QF_Sales_Rep'],
            'Sales manager': ['QF_Base_Access', 'QF_Sales_Rep', 'QF_Sales_Manager'],
            'Finance': ['QF_Base_Access', 'QF_Finance_Approver'],
            'Administrator': ['QF_Base_Access', 'QF_Admin'],
            'Integration user': ['QF_Integration_User'],
        },
        # Which selector methods each persona reaches through the services it is allowed to call.
        'uses': {
            'Sales rep': ['quotesById', 'quotesForUpdate', 'linesForQuotes', 'linesByIds', 'componentLinesForParents',
                          'lineTotalsByQuote', 'requestsForQuotes', 'opportunitiesById', 'productsById',
                          'pricebookEntriesByProduct', 'activeOptionsForBundles', 'catalogueEntries', 'activePricebooks',
                          'usersWithManager', 'activeUsersInRoles'],
            'Sales manager': ['quotesById', 'quotesForUpdate', 'requestForUpdate', 'requestsForQuotes', 'linesForQuotes',
                              'lineTotalsByQuote', 'usersWithManager', 'activeUsersInRoles'],
            'Finance': ['quotesById', 'quotesForUpdate', 'requestForUpdate', 'requestsForQuotes', 'lineTotalsByQuote',
                        'usersWithManager', 'activeUsersInRoles'],
            'Administrator': ['quotesById', 'quotesForUpdate', 'quotesForErp', 'linesForQuotes', 'requestsForQuotes'],
            'Integration user': ['quotesForErp', 'quotesDueForErpSync', 'linesForQuotes'],
        },
    },
    'lab': {
        'root': 'revops-lab/main/default',
        'selector': 'SalesQuoteSelector',
        'relations': {'Account__r': 'Account', 'Product__r': 'Product2', 'Opportunity__r': 'Opportunity'},
        'personas': {
            'Sales representative': ['Sales_Lab_Base', 'Sales_Representative_Access'],
            'Sales manager': ['Sales_Lab_Base', 'Sales_Representative_Access', 'Sales_Manager_Access'],
            'Finance manager': ['Sales_Lab_Base', 'Finance_Manager_Access'],
            'Sales director': ['Sales_Lab_Base', 'Sales_Representative_Access', 'Sales_Manager_Access', 'Sales_Director_Access'],
            'Integration user': ['Sales_Integration_Access'],
            'Administrator': ['Sales_Lab_Base', 'Sales_Administrator_Access'],
        },
        'uses': {
            'Sales representative': ['opportunitiesById', 'pricebookEntries', 'catalogue', 'quotesById', 'quotesForUpdate',
                                     'linesForQuotes', 'activePolicies', 'approvalRequestsForQuotes', 'usersWithManager',
                                     'activeUsersInRoles'],
            'Sales manager': ['quotesById', 'quotesForUpdate', 'approvalRequestsForQuotes', 'approvalRequestForUpdate'],
            'Finance manager': ['quotesById', 'quotesForUpdate', 'approvalRequestsForQuotes', 'approvalRequestForUpdate'],
            'Sales director': ['quotesById', 'quotesForUpdate', 'approvalRequestsForQuotes', 'approvalRequestForUpdate'],
            'Integration user': ['ordersForErp', 'orderItemsForOrders', 'ordersDueForErp'],
            'Administrator': ['ordersForErp', 'orderItemsForOrders', 'ordersDueForErp', 'quotesById', 'approvalRequestsForQuotes'],
        },
    },
}
ROOT = LAYERS['main']['root']
def field_perms(names):
    readable, objects = set(), set()
    for name in names:
        text = open(f'{ROOT}/permissionsets/{name}.permissionset-meta.xml').read()
        for block in re.findall(r'<fieldPermissions>(.*?)</fieldPermissions>', text, re.S):
            if '<readable>true' in block:
                readable.add(re.search(r'<field>(.*?)<', block).group(1))
        for block in re.findall(r'<objectPermissions>(.*?)</objectPermissions>', text, re.S):
            if '<allowRead>true' in block:
                objects.add(re.search(r'<object>(.*?)<', block).group(1))
    return readable, objects


def not_permissionable():
    result = set()
    for path in glob.glob(f'{ROOT}/objects/*/fields/*.field-meta.xml'):
        text = open(path).read()
        if '<required>true' in text or '<type>MasterDetail' in text:
            obj = path.split('/')[-3]
            result.add(f'{obj}.{os.path.basename(path).split(".")[0]}')
    return result


def selector_queries():
    text = open(f'{ROOT}/classes/{SELECTOR}.cls').read()
    methods = {}
    for match in re.finditer(r'public static [^(]+?\s(\w+)\(', text):
        start = match.end()
        nxt = re.search(r'\n    (public|private|@TestVisible)', text[start:])
        body = text[start:start + (nxt.start() if nxt else len(text))]
        for query in re.findall(r'\[\s*(SELECT.*?)\]', body, re.S):
            if 'WITH USER_MODE' not in query:
                continue
            obj = re.search(r'FROM\s+(\w+)', query).group(1)
            select = re.search(r'SELECT(.*?)FROM', query, re.S).group(1)
            fields = set()
            for token in re.split(r'[,\s]+', select):
                token = re.sub(r'^(SUM|MAX|COUNT)\(|\)$', '', token)
                if '__c' not in token:
                    continue
                parts = token.split('.')
                if len(parts) == 1:
                    fields.add(f'{obj}.{parts[0]}')
                elif parts[0].endswith('__r'):
                    target = RELATIONS.get(parts[0])
                    if target:
                        fields.add(f'{target}.{parts[1]}')
                elif parts[0] in ('Product2', 'Account', 'Opportunity'):
                    fields.add(f'{parts[0]}.{parts[1]}')
            for where_field in re.findall(r'([\w.]+__c)\s*(?:=|IN|<=|>=|!=)', query.split('FROM', 1)[1]):
                if '.' in where_field:
                    prefix, name = where_field.split('.', 1)
                    fields.add(f'{prefix}.{name}')
                else:
                    fields.add(f'{obj}.{where_field}')
            methods.setdefault(match.group(1), set()).update(fields)
    return methods


def check(layer):
    global ROOT, SELECTOR, RELATIONS
    config = LAYERS[layer]
    ROOT, SELECTOR, RELATIONS = config['root'], config['selector'], config['relations']
    skip = not_permissionable()
    queries = selector_queries()
    gaps = []
    for persona, sets in config['personas'].items():
        readable, objects = field_perms(sets)
        for method in config['uses'][persona]:
            if method not in queries:
                gaps.append(f'{layer} / {persona}: selector method {method} not found')
                continue
            for field in sorted(queries[method]):
                if field in skip or field in readable:
                    continue
                gaps.append(f'{layer} / {persona}: {method} reads {field} without FLS read')
    return gaps


def main():
    gaps = check('main') + check('lab')
    for gap in gaps:
        print('FLS GAP', gap)
    print(f'{len(gaps)} gap(s) across the main and lab persona sets')
    sys.exit(1 if gaps else 0)


if __name__ == '__main__':
    main()
